import Foundation

/// All vault I/O goes through NSFileCoordinator: for File Provider–backed
/// items (the Obsidian iCloud folder) a coordinated read blocks until the
/// item is materialized, which is what makes `.icloud` placeholders and
/// not-yet-downloaded files "just work".
enum VaultFileService {

    struct OpenResult {
        let url: URL
        let text: String
        let created: Bool
        let usedFallbackTemplate: Bool
    }

    /// Opens today's note, creating it from the vault template if absent.
    ///
    /// Existence is decided by an attempted coordinated read — never
    /// `fileExists` — so a note created on another device that has reached
    /// this device's metadata is found even if its content isn't downloaded.
    /// Creation re-checks inside the write coordination block, so losing a
    /// sync race means opening the other device's note, not clobbering it.
    static func openOrCreateToday(vault: URL, date: Date) throws -> OpenResult {
        let fileURL = vault.appending(path: MomentFormat.dailyNotePath(for: date))

        if let existing = try coordinatedRead(fileURL) {
            return OpenResult(url: fileURL, text: existing, created: false, usedFallbackTemplate: false)
        }

        let templateText = (try? coordinatedRead(vault.appending(path: VaultConfig.templatePath))) ?? nil
        let rendered = MomentFormat.renderTemplate(templateText ?? VaultConfig.fallbackTemplate, date: date)
        let (text, created) = try createIfAbsent(rendered, at: fileURL)
        return OpenResult(url: fileURL, text: text,
                          created: created,
                          usedFallbackTemplate: created && templateText == nil)
    }

    /// Coordinated read. Returns nil if the file doesn't exist; throws for
    /// real failures (offline + not downloaded, permissions). That
    /// distinction is load-bearing: "not found" may create a note,
    /// "failed" must never.
    static func coordinatedRead(_ url: URL, presenter: NSFilePresenter? = nil) throws -> String? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        var coordError: NSError?
        var contents: String?
        var innerError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                contents = String(decoding: try Data(contentsOf: readURL), as: UTF8.self)
            } catch {
                if isNotFound(error) { contents = nil } else { innerError = error }
            }
        }
        if let coordError {
            if isNotFound(coordError) { return nil }
            throw coordError
        }
        if let innerError { throw innerError }
        return contents
    }

    /// Coordinated write, creating intermediate directories (`2026/July/`).
    static func coordinatedWrite(_ text: String, to url: URL, presenter: NSFilePresenter? = nil) throws {
        var coordError: NSError?
        var innerError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(text.utf8).write(to: writeURL, options: .atomic)
            } catch {
                innerError = error
            }
        }
        if let error = coordError ?? (innerError as NSError?) { throw error }
    }

    /// Writes `text` to `url` unless the file appeared in the meantime
    /// (another device's note synced down between our read and this write) —
    /// in that case returns the existing content instead of overwriting.
    private static func createIfAbsent(_ text: String, at url: URL) throws -> (text: String, created: Bool) {
        var coordError: NSError?
        var innerError: Error?
        var result: (String, Bool) = (text, true)
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            do {
                if let data = try? Data(contentsOf: writeURL), !data.isEmpty {
                    result = (String(decoding: data, as: UTF8.self), false)
                } else {
                    try FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: writeURL, options: .atomic)
                }
            } catch {
                innerError = error
            }
        }
        if let error = coordError ?? (innerError as NSError?) { throw error }
        return result
    }

    /// Best-effort check used only to pick the loading message.
    static func isLikelyNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    private static func isNotFound(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        return false
    }
}

/// Watches the open note for changes made by other processes (iCloud sync
/// delivering desktop edits) and flushes our unsaved edits when another
/// process asks to read.
final class NotePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var onExternalChange: (() -> Void)?
    var onSaveRequested: ((@escaping (Error?) -> Void) -> Void)?

    init(url: URL) {
        self.presentedItemURL = url
        super.init()
    }

    func presentedItemDidChange() {
        onExternalChange?()
    }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        if let onSaveRequested {
            onSaveRequested(completionHandler)
        } else {
            completionHandler(nil)
        }
    }
}
