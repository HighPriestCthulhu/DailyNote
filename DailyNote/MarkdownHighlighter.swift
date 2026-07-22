import UIKit

/// Live markdown styling for the editor, with two modes sharing one pass:
///
/// - **Edit mode** (`conceal: false`): syntax stays visible; markers are
///   dimmed, content styled — the original behavior.
/// - **Markup mode** (`conceal: true`): marker ranges additionally get
///   `concealedKey`, which the editor's NSLayoutManager delegate renders as
///   null glyphs — invisible, but still present in the text. The paragraph
///   containing the caret (`activeParagraph`) is exempt, so the current line
///   reveals its raw markdown for editing, Obsidian-Live-Preview style.
///
/// Everything is attribute work on NSTextStorage; the string is never
/// mutated. Per-keystroke restyles stay scoped to single paragraphs.
struct MarkdownHighlighter {

    static let concealedKey = NSAttributedString.Key("dailynote.concealed")

    static let baseFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private static let boldFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
    private static func headingFont(level: Int) -> UIFont {
        let size: CGFloat = [24, 21, 19, 17, 17, 17][min(level, 6) - 1]
        return .monospacedSystemFont(ofSize: size, weight: .bold)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: UIColor.label]
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let markerColor = UIColor.secondaryLabel

    // MARK: Rules

    private struct Rule {
        let regex: NSRegularExpression
        let attributes: [NSAttributedString.Key: Any]
        /// Regex group to style (0 = whole match); other groups get marker
        /// styling and, in markup mode, concealment.
        let group: Int
        /// Claims its match range so later rules skip it (***bold italic***
        /// must not be re-matched by ** or *).
        var claims = false
    }

    private static let codeAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: UIColor.secondarySystemBackground,
        .foregroundColor: UIColor.systemPink,
    ]

    // Code spans run first and shield their content from later rules.
    private static let codeRules: [Rule] = [
        Rule(regex: rx(#"``(.+?)``"#), attributes: codeAttributes, group: 1),
        Rule(regex: rx(#"`([^`\n]+)`"#), attributes: codeAttributes, group: 1),
    ]

    private static let inlineRules: [Rule] = [
        // ***bold italic*** first, claiming its span so the plain bold rule
        // can't split it asymmetrically and leave a stray marker visible.
        Rule(regex: rx(#"\*\*\*(?!\s)(.+?)(?<!\s)\*\*\*"#),
             attributes: [.font: boldFont, .obliqueness: 0.18], group: 1, claims: true),
        Rule(regex: rx(#"(?<![\w_])___(?!\s)(.+?)(?<!\s)___(?![\w_])"#),
             attributes: [.font: boldFont, .obliqueness: 0.18], group: 1, claims: true),
        // **bold** / __bold__ — flanking rules: openers aren't followed by
        // whitespace and underscores never bind intraword.
        Rule(regex: rx(#"\*\*(?!\s)(.+?)(?<!\s)\*\*"#),
             attributes: [.font: boldFont], group: 1),
        Rule(regex: rx(#"(?<![\w_])__(?!\s)(.+?)(?<!\s)__(?![\w_])"#),
             attributes: [.font: boldFont], group: 1),
        // *italic* / _italic_
        Rule(regex: rx(#"(?<!\*)\*(?![\s\*])(.+?)(?<![\s\*])\*(?!\*)"#),
             attributes: [.obliqueness: 0.18], group: 1),
        Rule(regex: rx(#"(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#),
             attributes: [.obliqueness: 0.18], group: 1),
        // ~~strikethrough~~
        Rule(regex: rx(#"~~(.+?)~~"#),
             attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue], group: 1),
        // #tag (Obsidian-style, incl. nested/2026-Jul forms) — never concealed
        Rule(regex: rx(#"(?<=^|\s)#[A-Za-z0-9_][A-Za-z0-9_\-/]*"#),
             attributes: [.foregroundColor: UIColor.systemPurple], group: 0),
        // -[HH:MM] line timestamps — never concealed
        Rule(regex: rx(#"^-\[\d{1,2}:\d{2}\]"#),
             attributes: [.foregroundColor: UIColor.systemTeal], group: 0),
    ]

    private static let headingRegex = rx(#"^(#{1,6})[ \t].*$"#)
    private static let bulletRegex = rx(#"^[ \t]*([-*+]|\d+\.)[ \t]"#)
    private static let checkboxRegex = rx(#"^[ \t]*[-*+][ \t]\[[ xX]\]"#)
    private static let quoteRegex = rx(#"^>.*$"#)
    private static let ruleLineRegex = rx(#"^(---|\*\*\*|___)[ \t]*$"#)
    private static let wikiLinkRegex = rx(#"\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]"#)
    private static let mdLinkRegex = rx(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)

    // MARK: Entry points

    /// Restyle the whole document. Call on load, on mode toggle, and
    /// (debounced) after edits to fix multi-line constructs like frontmatter.
    func highlightDocument(_ storage: NSTextStorage, conceal: Bool = false,
                           activeParagraph: NSRange? = nil) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        highlight(storage, in: full, conceal: conceal, activeParagraph: activeParagraph)
        applyFrontmatter(storage)
        storage.endEditing()
    }

    /// Restyle just the paragraphs intersecting `range` — the per-keystroke
    /// and per-caret-move path.
    func highlightParagraphs(_ storage: NSTextStorage, around range: NSRange,
                             conceal: Bool = false, activeParagraph: NSRange? = nil) {
        let safe = Self.clamped(range, to: storage.length)
        let paragraphs = (storage.string as NSString).paragraphRange(for: safe)
        storage.beginEditing()
        highlight(storage, in: paragraphs, conceal: conceal, activeParagraph: activeParagraph)
        // Frontmatter stays dimmed data in every mode; re-assert it whenever a
        // partial restyle touches it (setAttributes also strips concealment).
        if let frontmatter = Self.frontmatterRange(in: storage.string) {
            let overlap = NSIntersectionRange(frontmatter, paragraphs)
            if overlap.length > 0 {
                storage.setAttributes([.font: Self.baseFont, .foregroundColor: UIColor.secondaryLabel],
                                      range: overlap)
            }
        }
        storage.endEditing()
    }

    static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    // MARK: Core pass

    private func highlight(_ storage: NSTextStorage, in range: NSRange,
                           conceal: Bool, activeParagraph: NSRange?) {
        storage.setAttributes(Self.baseAttributes, range: range)
        let string = storage.string

        func isActive(_ matchRange: NSRange) -> Bool {
            guard let active = activeParagraph else { return false }
            return NSIntersectionRange(active, matchRange).length > 0
        }
        func hide(_ r: NSRange, matchRange: NSRange) {
            guard conceal, r.length > 0, !isActive(matchRange) else { return }
            storage.addAttribute(Self.concealedKey, value: true, range: r)
        }

        // Line-level styles (list/quote markers stay visible in both modes)
        Self.headingRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            let marker = match.range(at: 1)
            storage.addAttribute(.font, value: Self.headingFont(level: marker.length), range: match.range)
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: marker)
            hide(NSRange(location: marker.location, length: marker.length + 1), matchRange: match.range)
        }
        Self.quoteRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttributes([.foregroundColor: Self.markerColor, .obliqueness: 0.18],
                                  range: match.range)
        }
        Self.bulletRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: match.range(at: 1))
        }
        Self.checkboxRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: match.range)
        }
        Self.ruleLineRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: match.range)
        }

        // Code spans first; their ranges shield content from later rules.
        var protected: [NSRange] = []
        for rule in Self.codeRules {
            rule.regex.enumerateMatches(in: string, range: range) { match, _, _ in
                guard let match else { return }
                if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { return }
                let content = match.range(at: rule.group)
                storage.addAttributes(rule.attributes, range: content)
                let head = NSRange(location: match.range.location,
                                   length: content.location - match.range.location)
                let tail = NSRange(location: content.location + content.length,
                                   length: match.range.location + match.range.length
                                           - content.location - content.length)
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: head)
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: tail)
                hide(head, matchRange: match.range)
                hide(tail, matchRange: match.range)
                protected.append(match.range)
            }
        }
        func isProtected(_ r: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // Links: whole construct styled in edit mode; markers (and the
        // target of an aliased wikilink) concealed in markup mode.
        Self.wikiLinkRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, !isProtected(match.range) else { return }
            let alias = match.range(at: 2)
            let display = alias.location != NSNotFound ? alias : match.range(at: 1)
            storage.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: match.range)
            hide(NSRange(location: match.range.location,
                         length: display.location - match.range.location), matchRange: match.range)
            hide(NSRange(location: display.location + display.length,
                         length: match.range.location + match.range.length
                                 - display.location - display.length), matchRange: match.range)
        }
        Self.mdLinkRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, !isProtected(match.range) else { return }
            let title = match.range(at: 1)
            storage.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: match.range)
            hide(NSRange(location: match.range.location, length: 1), matchRange: match.range)
            hide(NSRange(location: title.location + title.length,
                         length: match.range.location + match.range.length
                                 - title.location - title.length), matchRange: match.range)
        }

        // Inline emphasis, tags, timestamps
        for rule in Self.inlineRules {
            rule.regex.enumerateMatches(in: string, range: range) { match, _, _ in
                guard let match, !isProtected(match.range) else { return }
                if rule.claims { protected.append(match.range) }
                storage.addAttributes(rule.attributes, range: match.range(at: rule.group))
                if rule.group != 0 {
                    let content = match.range(at: rule.group)
                    let head = NSRange(location: match.range.location,
                                       length: content.location - match.range.location)
                    let tail = NSRange(location: content.location + content.length,
                                       length: match.range.location + match.range.length
                                               - content.location - content.length)
                    storage.addAttribute(.foregroundColor, value: Self.markerColor, range: head)
                    storage.addAttribute(.foregroundColor, value: Self.markerColor, range: tail)
                    hide(head, matchRange: match.range)
                    hide(tail, matchRange: match.range)
                }
            }
        }
    }

    /// Dim the leading YAML frontmatter block (`---` … `---`). Kept visible
    /// in both modes — it's data, not markup.
    private func applyFrontmatter(_ storage: NSTextStorage) {
        guard let range = Self.frontmatterRange(in: storage.string) else { return }
        storage.setAttributes([.font: Self.baseFont, .foregroundColor: UIColor.secondaryLabel],
                              range: range)
    }

    /// Range of the leading YAML frontmatter, through its closing fence. The
    /// closing `---` must sit alone on its line; lines like `--- draft` are
    /// skipped and the search continues.
    static func frontmatterRange(in text: String) -> NSRange? {
        guard text.hasPrefix("---\n") else { return nil }
        let ns = text as NSString
        var searchFrom = 3
        while searchFrom < ns.length {
            let fence = ns.range(of: "\n---",
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard fence.location != NSNotFound else { return nil }
            var end = fence.location + fence.length
            if end >= ns.length || ns.character(at: end) == UInt8(ascii: "\n") {
                if end < ns.length { end += 1 } // include the newline
                return NSRange(location: 0, length: end)
            }
            searchFrom = fence.location + 1
        }
        return nil
    }
}
