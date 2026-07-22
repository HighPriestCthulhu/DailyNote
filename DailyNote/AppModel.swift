import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class AppModel {

    enum State {
        case launching
        case needsFolder(message: String?)
        case loading(message: String)
        case editing
        case error(message: String)
    }

    private(set) var state: State = .launching
    private(set) var noteURL: URL?
    private(set) var noteDate: Date?
    private(set) var saveFailed = false
    private(set) var usedFallbackTemplate = false

    /// Bumped each time a different document (or external change) is loaded
    /// into `noteText`. The editor re-reads `noteText` only when this moves.
    private(set) var noteGeneration = 0

    /// Deliberately outside observation: keystrokes update this via
    /// `editorChangedText` without invalidating any SwiftUI view.
    @ObservationIgnored private(set) var noteText: String = ""

    var noteTitle: String {
        noteURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// True when the editor should grab focus on its next mount (fresh
    /// document). Cleared by the editor after focusing, so remounts from
    /// toggling reading mode don't steal the caret or raise the keyboard.
    @ObservationIgnored var editorNeedsInitialFocus = true

    @ObservationIgnored private var vaultURL: URL?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var presenter: NotePresenter?
    @ObservationIgnored private var didLaunch = false
    /// Monotonic id for openToday calls; stale completions are dropped so
    /// overlapping opens can't double-register presenters or clobber state.
    @ObservationIgnored private var openSequence = 0
    /// Disk content the instant-open cache displayed, kept until the
    /// background reconcile compares it against the real disk state.
    @ObservationIgnored private var reconcileBaseText: String?

    private static let rescueBufferKey = "rescueBuffer"
    private static let rescueBufferPathKey = "rescueBufferPath"
    // Last content known to match disk, keyed by note path: shown instantly
    // at launch while the coordinated iCloud open reconciles in background.
    private static let cachedNotePathKey = "cachedNotePath"
    private static let cachedNoteTextKey = "cachedNoteText"

    init() {
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sceneBecameActive() }
        }
    }

    // MARK: - Launch / open

    func launchIfNeeded() {
        guard !didLaunch else { return }
        didLaunch = true
        #if DEBUG
        // Simulator/UI-test hook: bypass the bookmark and use a local folder.
        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-vault"),
           idx + 1 < ProcessInfo.processInfo.arguments.count {
            vaultURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[idx + 1], isDirectory: true)
            showCachedNoteIfAvailable()
            openToday()
            return
        }
        #endif
        guard let url = BookmarkStore.resolve() else {
            state = .needsFolder(message: nil)
            return
        }
        _ = url.startAccessingSecurityScopedResource() // held for the session
        vaultURL = url
        showCachedNoteIfAvailable()
        openToday()
    }

    /// Instant open: if we have cached content for today's note, put the
    /// editor up immediately; `openToday` reconciles with disk afterwards.
    private func showCachedNoteIfAvailable() {
        guard let vault = vaultURL else { return }
        let day = Date()
        let fileURL = vault.appending(path: MomentFormat.dailyNotePath(for: day))
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.cachedNotePathKey) == fileURL.path,
              var text = defaults.string(forKey: Self.cachedNoteTextKey) else { return }

        reconcileBaseText = text // what we believe is on disk right now

        var restoredRescue = false
        if defaults.string(forKey: Self.rescueBufferPathKey) == fileURL.path,
           let rescued = defaults.string(forKey: Self.rescueBufferKey), rescued != text {
            text = rescued // crashed/offline edits beat the older cache
            restoredRescue = true
        }
        noteURL = fileURL
        noteDate = day
        editorNeedsInitialFocus = true
        setTextProgrammatically(text)
        // Watch for external changes from the start, even if the background
        // reconcile later fails (offline launch).
        attachPresenter(to: fileURL)
        state = .editing
        if restoredRescue { markDirty() }
    }

    private func updateCache(url: URL, text: String) {
        UserDefaults.standard.set(url.path, forKey: Self.cachedNotePathKey)
        UserDefaults.standard.set(text, forKey: Self.cachedNoteTextKey)
    }

    func openToday() {
        guard let vault = vaultURL else {
            state = .needsFolder(message: nil)
            return
        }
        let day = Date()
        let fileURL = vault.appending(path: MomentFormat.dailyNotePath(for: day))
        // When the cache already put this note on screen, reconcile silently
        // behind the live editor instead of flashing a loading screen.
        let alreadyShowing: Bool = {
            if case .editing = state, noteURL == fileURL { return true }
            return false
        }()
        if !alreadyShowing {
            let syncing = VaultFileService.isLikelyNotDownloaded(fileURL)
            state = .loading(message: syncing ? "Syncing from iCloud…" : "Opening today's note…")
            detachPresenter()
        }
        openSequence += 1
        let sequence = openSequence

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<VaultFileService.OpenResult, Error>
            do {
                outcome = .success(try VaultFileService.openOrCreateToday(vault: vault, date: day))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishOpen(outcome, day: day, sequence: sequence)
        }
    }

    func retry() {
        openToday()
    }

    private func finishOpen(_ outcome: Result<VaultFileService.OpenResult, Error>, day: Date, sequence: Int) {
        guard sequence == openSequence else { return } // superseded by a newer open
        switch outcome {
        case .success(let result):
            let reconciling: Bool = {
                if case .editing = state, noteURL == result.url { return true }
                return false
            }()
            noteURL = result.url
            noteDate = day
            usedFallbackTemplate = result.usedFallbackTemplate
            attachPresenter(to: result.url)

            if reconciling {
                reconcile(with: result)
                return
            }

            dirty = false
            saveFailed = false
            editorNeedsInitialFocus = true

            // Crash/offline safety net: text that never reached disk is
            // restored and queued for another save attempt.
            var text = result.text
            if UserDefaults.standard.string(forKey: Self.rescueBufferPathKey) == result.url.path,
               let rescued = UserDefaults.standard.string(forKey: Self.rescueBufferKey),
               rescued != text {
                text = rescued
            }
            setTextProgrammatically(text)
            state = .editing
            if text != result.text {
                markDirty()
            } else {
                updateCache(url: result.url, text: text)
            }
        case .failure(let error):
            // If the cache already put the note on screen, keep it editable —
            // a failed background reconcile shouldn't eject the user. The
            // presenter (attached at cache time) and per-save error badge
            // cover the rest of the session.
            if case .editing = state { return }
            state = .error(message: "Couldn't open today's note.\n\(error.localizedDescription)")
        }
    }

    /// The instant-open cache showed `reconcileBaseText`; now the coordinated
    /// read tells us what disk really holds. Policy:
    /// - untouched buffer → adopt disk when it changed
    /// - buffer appended onto the shown base while disk also moved on → rebase
    ///   our suffix onto the disk text (the common quick-capture race)
    /// - anything else → the buffer wins (it may already be saved; a stale
    ///   read must never revert it)
    private func reconcile(with result: VaultFileService.OpenResult) {
        let base = reconcileBaseText
        reconcileBaseText = nil

        if !dirty {
            let bufferUntouched = (base == nil) || (noteText == base)
            if bufferUntouched {
                if noteText != result.text { setTextProgrammatically(result.text) }
                updateCache(url: result.url, text: result.text)
            }
            // Clean but not matching base: a save raced ahead of this read;
            // flushSave already updated the cache with the newer text.
            return
        }

        if let base, result.text != base,
           noteText.hasPrefix(base), result.text.hasPrefix(base) {
            // Typed onto a stale base while disk gained content: keep both.
            let suffix = String(noteText.dropFirst(base.count))
            setTextProgrammatically(result.text + suffix)
            markDirty()
        }
        // Otherwise: unsaved edits win, as everywhere else in the app.
    }

    // MARK: - Folder picking

    func folderPicked(_ pickedURL: URL) {
        let started = pickedURL.startAccessingSecurityScopedResource()
        let dailyNotes = pickedURL.appending(path: VaultConfig.dailyNotesFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dailyNotes.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if started { pickedURL.stopAccessingSecurityScopedResource() }
            state = .needsFolder(message: "That folder has no “\(VaultConfig.dailyNotesFolder)” inside it — pick the vault folder itself (e.g. “Diary”).")
            return
        }
        try? BookmarkStore.save(pickedURL)
        if let old = vaultURL { old.stopAccessingSecurityScopedResource() }
        vaultURL = pickedURL
        openToday()
    }

    // MARK: - Saving

    /// Called by the editor on every keystroke. Touches only unobserved
    /// state — typing never triggers a SwiftUI render pass.
    func editorChangedText(_ text: String) {
        guard text != noteText else { return }
        noteText = text
        markDirty()
    }

    private func markDirty() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.flushSave()
        }
    }

    func flushSave() async {
        saveTask?.cancel()
        guard dirty, let url = noteURL else { return }
        let text = noteText
        let notePresenter = presenter
        do {
            try await Task.detached(priority: .utility) {
                try VaultFileService.coordinatedWrite(text, to: url, presenter: notePresenter)
            }.value
            if noteText == text { dirty = false } // more typing arrived mid-write → stay dirty
            if saveFailed { saveFailed = false }
            updateCache(url: url, text: text)
            UserDefaults.standard.removeObject(forKey: Self.rescueBufferKey)
            UserDefaults.standard.removeObject(forKey: Self.rescueBufferPathKey)
        } catch {
            if !saveFailed { saveFailed = true }
            // Crash/offline safety net; retried on the next edit or scene change.
            UserDefaults.standard.set(text, forKey: Self.rescueBufferKey)
            UserDefaults.standard.set(url.path, forKey: Self.rescueBufferPathKey)
        }
    }

    // MARK: - Scene lifecycle

    func sceneBecameActive() {
        guard didLaunch, vaultURL != nil else { return }
        if case .error = state { return } // user retries explicitly
        if let noteDate, !Calendar.current.isDate(noteDate, inSameDayAs: Date()) {
            Task {
                await flushSave() // flushes to the old day's URL
                // If the flush failed, stay on the old note ("not saved"
                // badge showing) rather than discarding the edits; rollover
                // retries on the next activation.
                guard !dirty else { return }
                openToday()
            }
        } else if case .editing = state {
            reloadFromDiskIfClean() // pick up desktop edits made while suspended
        }
    }

    func sceneWillResign() {
        guard dirty else { return }
        let taskID = UIApplication.shared.beginBackgroundTask()
        Task {
            await flushSave()
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    // MARK: - External changes (NSFilePresenter)

    private func attachPresenter(to url: URL) {
        detachPresenter() // never stack registrations
        let notePresenter = NotePresenter(url: url)
        notePresenter.onExternalChange = { [weak self] in
            Task { @MainActor in self?.reloadFromDiskIfClean() }
        }
        notePresenter.onSaveRequested = { [weak self] done in
            Task { @MainActor in
                await self?.flushSave()
                done(nil)
            }
        }
        NSFileCoordinator.addFilePresenter(notePresenter)
        presenter = notePresenter
    }

    private func detachPresenter() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
    }

    /// Reload the buffer from disk after an external change — but only if we
    /// have no unsaved edits (last-writer-wins, deliberately simple).
    private func reloadFromDiskIfClean() {
        guard !dirty, let url = noteURL else { return }
        let notePresenter = presenter
        Task.detached { [weak self] in
            guard let text = ((try? VaultFileService.coordinatedRead(url, presenter: notePresenter)) ?? nil) else { return }
            await self?.applyExternalText(text, for: url)
        }
    }

    private func applyExternalText(_ text: String, for url: URL) {
        guard !dirty, noteURL == url, text != noteText else { return }
        setTextProgrammatically(text)
    }

    private func setTextProgrammatically(_ text: String) {
        noteText = text
        noteGeneration += 1
    }
}
