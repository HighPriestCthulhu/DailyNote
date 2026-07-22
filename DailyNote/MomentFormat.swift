import Foundation

/// Formats dates using the moment.js token subset Obsidian uses in daily-note
/// paths and `{{date:...}}` template placeholders.
///
/// Moment and ICU (DateFormatter) disagree on two tokens, so patterns must
/// never be passed to DateFormatter directly:
///   - moment `YYYY` = calendar year, ICU `YYYY` = week-based year (wrong around New Year)
///   - moment `DD`   = day of month,  ICU `DD`   = day of year
enum MomentFormat {

    /// moment token → ICU pattern. Scanned longest-first, so order here doesn't matter.
    private static let tokenMap: [String: String] = [
        "YYYY": "yyyy", "yyyy": "yyyy", "YY": "yy",
        "MMMM": "MMMM", "MMM": "MMM", "MM": "MM", "M": "M",
        "DD": "dd", "D": "d",
        "dddd": "EEEE", "ddd": "EEE",
        "HH": "HH", "H": "H", "hh": "hh", "h": "h",
        "mm": "mm", "m": "m",
        "ss": "ss", "s": "s",
        "A": "a", "a": "a",
    ]

    private static let tokensLongestFirst: [String] = tokenMap.keys.sorted { $0.count > $1.count }

    private static var formatterCache: [String: DateFormatter] = [:]
    private static let cacheLock = NSLock()

    private static func formatter(icu: String) -> DateFormatter {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = formatterCache[icu] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = icu
        formatterCache[icu] = f
        return f
    }

    /// Formats `date` with a moment-style pattern. Non-token characters
    /// (`/`, `-`, `_`, spaces, …) pass through literally; each token is
    /// formatted independently so ICU literal-quoting never comes into play.
    static func format(_ pattern: String, date: Date) -> String {
        var out = ""
        var idx = pattern.startIndex
        scan: while idx < pattern.endIndex {
            for token in tokensLongestFirst where pattern[idx...].hasPrefix(token) {
                out += formatter(icu: tokenMap[token]!).string(from: date)
                idx = pattern.index(idx, offsetBy: token.count)
                continue scan
            }
            out.append(pattern[idx])
            idx = pattern.index(after: idx)
        }
        return out
    }

    /// Replaces `{{date}}`, `{{time}}`, and `{{date:FORMAT}}` / `{{time:FORMAT}}`
    /// placeholders the way Obsidian's daily-notes template does.
    static func renderTemplate(_ text: String, date: Date) -> String {
        var result = text
        result = result.replacingOccurrences(of: "{{date}}", with: format("YYYY-MM-DD", date: date))
        result = result.replacingOccurrences(of: "{{time}}", with: format("HH:mm", date: date))

        let regex = try! NSRegularExpression(pattern: #"\{\{(?:date|time):([^}]+)\}\}"#)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let fmtRange = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: format(String(result[fmtRange]), date: date))
        }
        return result
    }

    /// Vault-relative path of the daily note for `date`,
    /// e.g. `daily_notes/2026/July/2026-Jul-15-Wed.md`.
    static func dailyNotePath(
        for date: Date,
        folder: String = VaultConfig.dailyNotesFolder,
        pattern: String = VaultConfig.dailyNoteFormat
    ) -> String {
        folder + "/" + format(pattern, date: date) + ".md"
    }
}

/// Mirrors the vault's `.obsidian/daily-notes.json`.
enum VaultConfig {
    static let dailyNotesFolder = "daily_notes"
    static let dailyNoteFormat = "YYYY/MMMM/YYYY-MMM-DD-ddd"
    static let templatePath = "daily_notes/0000.md"

    /// Byte-exact copy of `daily_notes/0000.md`, used only if the vault's
    /// template can't be read.
    static let fallbackTemplate = """
    ---
    tags:
      - daily_note
    date: "{{date:YYYY-MMM-DD}}"
    ---





    #{{date:YYYY-MMM}}
    #Year_{{date:yyyy}}
    [[daily_notes/{{date:YYYY/MMMM}}]]

    """
}
