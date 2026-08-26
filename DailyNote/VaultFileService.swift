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

    // MARK: - History (timeline mode)

    struct HistoryDay {
        let date: Date
        /// Filename stem, e.g. `2026-Jul-21-Tue` — used as the day header.
        let title: String
        /// Note text with YAML frontmatter stripped and edges trimmed.
        let body: String
    }

    struct HistoryBatch {
        /// Oldest-first, ready to prepend as one chunk.
        let days: [HistoryDay]
        /// Day before the last scanned date — where the next batch starts.
        let nextDate: Date?
        let reachedEnd: Bool
    }

    /// Walks backwards from `lastDay` (inclusive) collecting up to `batchSize`
    /// existing notes. Missing days are skipped; `missLimit` consecutive
    /// misses ends the walk. Blocking (coordinated reads) — call off-main.
    static func readHistory(vault: URL, endingAt lastDay: Date,
                            batchSize: Int = 5, missLimit: Int = 92) -> HistoryBatch {
        let calendar = Calendar.current
        var found: [HistoryDay] = [] // newest-first while collecting
        var current = lastDay
        var consecutiveMisses = 0

        while found.count < batchSize && consecutiveMisses < missLimit {
            let url = vault.appending(path: MomentFormat.dailyNotePath(for: current))
            let text: String?
            do {
                text = try coordinatedRead(url)
            } catch {
                // A real read failure (offline, not yet downloaded) is not a
                // missing day: stop this batch here and let the next batch
                // retry from the same date, so no day is silently dropped.
                return HistoryBatch(days: found.reversed(), nextDate: current, reachedEnd: false)
            }
            if let text {
                consecutiveMisses = 0
                var body = text
                if let fm = frontmatterRange(in: body as NSString, at: 0) {
                    body = ((body as NSString).substring(from: fm.location + fm.length))
                }
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                // A note that is only frontmatter has nothing to show — a
                // bare day header would just be noise in the timeline.
                if !body.isEmpty {
                    found.append(HistoryDay(date: current,
                                            title: url.deletingPathExtension().lastPathComponent,
                                            body: body))
                }
            } else {
                consecutiveMisses += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: current) else { break }
            current = previous
        }

        let reachedEnd = consecutiveMisses >= missLimit
        return HistoryBatch(days: found.reversed(),
                            nextDate: reachedEnd ? nil : current,
                            reachedEnd: reachedEnd)
    }

    /// Range of a YAML frontmatter block starting exactly at `offset`
    /// (`---` fence through the closing fence's newline). The closing `---`
    /// must sit alone on its line; lines like `--- draft` are skipped and the
    /// search continues. Canonical implementation — the highlighter delegates
    /// here so display and storage agree on what frontmatter is.
    static func frontmatterRange(in text: NSString, at offset: Int) -> NSRange? {
        let lf = unichar(0x0A), cr = unichar(0x0D)
        // Opening fence: "---" followed by \n or \r\n.
        guard offset >= 0, offset + 3 <= text.length,
              text.substring(with: NSRange(location: offset, length: 3)) == "---" else { return nil }
        var bodyStart = offset + 3
        if bodyStart < text.length, text.character(at: bodyStart) == cr { bodyStart += 1 }
        guard bodyStart < text.length, text.character(at: bodyStart) == lf else { return nil }

        var searchFrom = bodyStart
        while searchFrom < text.length {
            let fence = text.range(of: "\n---",
                                   range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard fence.location != NSNotFound else { return nil }
            var end = fence.location + fence.length
            if end < text.length, text.character(at: end) == cr { end += 1 }
            if end >= text.length || text.character(at: end) == lf {
                if end < text.length { end += 1 } // include the line break
                return NSRange(location: offset, length: end - offset)
            }
            searchFrom = fence.location + 1
        }
        return nil
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
