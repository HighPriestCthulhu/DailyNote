import SwiftUI
import UIKit

/// Plain UITextView wrapper with live markdown styling and an optional
/// Obsidian-Live-Preview "markup mode". TextKit 1, no animations.
///
/// Markup mode never swaps views or mutates text: marker characters carry a
/// conceal attribute that the NSLayoutManager delegate renders as null
/// glyphs (invisible). The paragraph under the caret is exempt, so the line
/// being edited shows raw markdown. Toggling modes, moving the caret, and
/// typing are all attribute-only restyles scoped to one or two paragraphs.
///
/// Performance contract: typing never re-enters SwiftUI. Keystrokes flow
/// UITextView → `onTextChange` (into unobserved model state); this view only
/// re-reads `text` when `generation` changes (a different document was
/// loaded).
struct PlainTextEditor: UIViewRepresentable {
    let text: String
    let generation: Int
    let onTextChange: (String) -> Void
    let startAtEnd: Bool
    /// When on, each Return starts the new line with a `-[HH:MM] ` stamp.
    let timestampNewLines: Bool
    /// Live-preview rendering: conceal markers everywhere but the caret line.
    let markupMode: Bool
    let autoFocus: Bool
    let onAutoFocused: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func newlineTimestamp(at date: Date = Date()) -> String {
        "\n-[" + timeFormatter.string(from: date) + "] "
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.layoutManager.delegate = context.coordinator
        textView.font = MarkdownHighlighter.baseFont
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // Smart punctuation corrupts markdown (`--`, quotes in code/frontmatter).
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .default
        context.coordinator.observeKeyboard(for: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastGeneration != generation {
            context.coordinator.lastGeneration = generation
            let selection = textView.selectedRange
            let wasAtEnd = selection.location >= (textView.text as NSString).length
            textView.text = text
            let length = (text as NSString).length
            // A caret at the end (the capture position) stays at the end when
            // reconciled content arrives; otherwise clamp in place.
            textView.selectedRange = NSRange(location: wasAtEnd ? length : min(selection.location, length),
                                             length: 0)
            context.coordinator.fullRestyle(textView)
        }

        if context.coordinator.lastMarkupMode != markupMode {
            context.coordinator.lastMarkupMode = markupMode
            context.coordinator.fullRestyle(textView)
        }

        if autoFocus, !context.coordinator.didInitialFocus {
            context.coordinator.didInitialFocus = true
            let goToEnd = startAtEnd
            let focused = onAutoFocused
            DispatchQueue.main.async {
                UIView.performWithoutAnimation {
                    if goToEnd { Self.moveCaretToEnd(textView) }
                    textView.becomeFirstResponder()
                }
                focused()
            }
        }
    }

    private static func moveCaretToEnd(_ textView: UITextView) {
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.selectedRange = end
        textView.scrollRangeToVisible(end)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, NSLayoutManagerDelegate {
        var parent: PlainTextEditor
        var didInitialFocus = false
        var lastGeneration = Int.min
        var lastMarkupMode: Bool
        let highlighter = MarkdownHighlighter()

        private var lastActiveParagraph = NSRange(location: 0, length: 0)
        /// Whether the last full pass left concealed glyphs — toggling markup
        /// OFF still needs one invalidation to regenerate them.
        private var lastPassConcealed = false
        private weak var textView: UITextView?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var fullHighlightWork: DispatchWorkItem?

        init(_ parent: PlainTextEditor) {
            self.parent = parent
            self.lastMarkupMode = parent.markupMode
        }

        // MARK: Styling

        private func activeParagraph(_ textView: UITextView) -> NSRange {
            let ns = textView.text as NSString
            let selection = MarkdownHighlighter.clamped(textView.selectedRange, to: ns.length)
            return ns.paragraphRange(for: selection)
        }

        func fullRestyle(_ textView: UITextView) {
            let active = activeParagraph(textView)
            lastActiveParagraph = active
            highlighter.highlightDocument(textView.textStorage,
                                          conceal: parent.markupMode,
                                          activeParagraph: active)
            if parent.markupMode || lastPassConcealed {
                invalidateGlyphs(textView, in: NSRange(location: 0, length: textView.textStorage.length))
            }
            lastPassConcealed = parent.markupMode
        }

        /// Restyle the paragraphs around `range`; in markup mode also
        /// regenerate their glyphs so concealment changes take effect.
        private func restyle(_ textView: UITextView, around range: NSRange, active: NSRange) {
            highlighter.highlightParagraphs(textView.textStorage, around: range,
                                            conceal: parent.markupMode,
                                            activeParagraph: active)
            if parent.markupMode {
                let ns = textView.text as NSString
                invalidateGlyphs(textView, in: ns.paragraphRange(
                    for: MarkdownHighlighter.clamped(range, to: ns.length)))
            }
        }

        private func invalidateGlyphs(_ textView: UITextView, in range: NSRange) {
            textView.layoutManager.invalidateGlyphs(forCharacterRange: range,
                                                    changeInLength: 0, actualCharacterRange: nil)
            textView.layoutManager.invalidateLayout(forCharacterRange: range,
                                                    actualCharacterRange: nil)
        }

        // MARK: NSLayoutManagerDelegate — concealment

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes charIndexes: UnsafePointer<Int>,
                           font aFont: UIFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            guard parent.markupMode, let storage = layoutManager.textStorage else { return 0 }
            var newProps: [NSLayoutManager.GlyphProperty] = []
            var modified = false
            newProps.reserveCapacity(glyphRange.length)
            for i in 0..<glyphRange.length {
                let charIndex = charIndexes[i]
                if charIndex < storage.length,
                   storage.attribute(MarkdownHighlighter.concealedKey, at: charIndex,
                                     effectiveRange: nil) != nil {
                    newProps.append(.null)
                    modified = true
                } else {
                    newProps.append(props[i])
                }
            }
            guard modified else { return 0 }
            newProps.withUnsafeBufferPointer { buffer in
                layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!,
                                        characterIndexes: charIndexes, font: aFont,
                                        forGlyphRange: glyphRange)
            }
            return glyphRange.length
        }

        // MARK: Active-line reveal

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard parent.markupMode else { return }
            let newActive = activeParagraph(textView)
            guard newActive != lastActiveParagraph else { return }
            let ns = textView.text as NSString
            // The departed active range can span several paragraphs (drag
            // selections) — re-conceal ALL of it, then reveal the new range.
            let old = MarkdownHighlighter.clamped(lastActiveParagraph, to: ns.length)
            lastActiveParagraph = newActive
            restyle(textView, around: old, active: newActive)
            restyle(textView, around: newActive, active: newActive)
        }

        // MARK: Return-key handling (lists, timestamps)

        // Matched against the current line on Return. Group 1 = indent,
        // group 2 = the whole marker (through its trailing space), last
        // group = item content.
        private static let checkboxLine = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+] \[[ xX]\] )(.*)$"#)
        private static let bulletLine = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+] )(.*)$"#)
        private static let numberLine = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+)([.)] )(.*)$"#)

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            // Only a typed Return gets special handling — pastes pass through.
            guard text == "\n" else { return true }

            let ns = textView.text as NSString
            var lineRange = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A {
                lineRange.length -= 1
            }
            let line = ns.substring(with: lineRange)
            let full = NSRange(location: 0, length: (line as NSString).length)

            // List continuation wins over timestamps.
            if let m = Self.checkboxLine.firstMatch(in: line, range: full) {
                return continueList(textView, at: range, line: line, lineRange: lineRange,
                                    indent: m.range(at: 1), marker: m.range(at: 2),
                                    content: m.range(at: 3),
                                    // new items always start unchecked
                                    nextMarker: (line as NSString).substring(with: m.range(at: 2))
                                        .replacingOccurrences(of: "[x]", with: "[ ]")
                                        .replacingOccurrences(of: "[X]", with: "[ ]"))
            }
            if let m = Self.bulletLine.firstMatch(in: line, range: full) {
                return continueList(textView, at: range, line: line, lineRange: lineRange,
                                    indent: m.range(at: 1), marker: m.range(at: 2),
                                    content: m.range(at: 3),
                                    nextMarker: (line as NSString).substring(with: m.range(at: 2)))
            }
            if let m = Self.numberLine.firstMatch(in: line, range: full) {
                let lineNS = line as NSString
                let number = Int(lineNS.substring(with: m.range(at: 2))) ?? 0
                let markerRange = NSRange(location: m.range(at: 2).location,
                                          length: m.range(at: 3).location + m.range(at: 3).length
                                                  - m.range(at: 2).location)
                return continueList(textView, at: range, line: line, lineRange: lineRange,
                                    indent: m.range(at: 1), marker: markerRange,
                                    content: m.range(at: 4),
                                    nextMarker: "\(number + 1)" + lineNS.substring(with: m.range(at: 3)))
            }

            if parent.timestampNewLines {
                insert(PlainTextEditor.newlineTimestamp(), into: textView, replacing: range)
                return false
            }
            return true
        }

        /// Continue a list on Return: repeat the marker on the new line, or —
        /// when the current item is empty — remove the marker and exit the
        /// list (matching Obsidian).
        private func continueList(_ textView: UITextView, at range: NSRange, line: String,
                                  lineRange: NSRange, indent: NSRange, marker: NSRange,
                                  content: NSRange, nextMarker: String) -> Bool {
            let lineNS = line as NSString
            let contentText = lineNS.substring(with: content)
            // Return only counts as "inside the item" past the marker;
            // before/inside the marker a plain newline is less surprising.
            let caretInLine = range.location - lineRange.location
            guard caretInLine >= marker.location + marker.length else { return true }

            if contentText.trimmingCharacters(in: .whitespaces).isEmpty {
                // With an active selection there is no "empty item" intent —
                // let UIKit replace the selection with a plain newline.
                guard range.length == 0 else { return true }
                // Empty item → exit list: strip indent + marker, no newline.
                let strip = NSRange(location: lineRange.location,
                                    length: marker.location + marker.length - indent.location)
                insert("", into: textView, replacing: strip)
                return false
            }

            let insertText = "\n" + lineNS.substring(with: indent) + nextMarker
            insert(insertText, into: textView, replacing: range)
            return false
        }

        /// Programmatic edit routed through the text-input system so the undo
        /// stack stays consistent with the user's typing. Falls back to a raw
        /// storage edit (clearing undo, which is safe) if position math fails.
        private func insert(_ string: String, into textView: UITextView, replacing range: NSRange) {
            if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
               let end = textView.position(from: start, offset: range.length),
               let textRange = textView.textRange(from: start, to: end) {
                textView.replace(textRange, withText: string)
            } else {
                textView.textStorage.replaceCharacters(in: range, with: string)
                textView.undoManager?.removeAllActions()
            }
            let caret = NSRange(location: range.location + (string as NSString).length, length: 0)
            textView.selectedRange = caret
            textView.scrollRangeToVisible(caret)
            textViewDidChange(textView)
        }

        // MARK: Text changes

        func textViewDidChange(_ textView: UITextView) {
            parent.onTextChange(textView.text)

            // Cheap per-keystroke styling: the current paragraph, plus the
            // departed range when the caret crossed a line boundary (Return)
            // or a selection was replaced, so it re-conceals in markup mode.
            let ns = textView.text as NSString
            let newActive = activeParagraph(textView)
            let old = MarkdownHighlighter.clamped(lastActiveParagraph, to: ns.length)
            if parent.markupMode, old != newActive {
                restyle(textView, around: old, active: newActive)
            }
            lastActiveParagraph = newActive
            restyle(textView, around: newActive, active: newActive)
            textView.typingAttributes = MarkdownHighlighter.baseAttributes

            // …and a debounced full pass for multi-line constructs
            // (frontmatter, pasted blocks).
            fullHighlightWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.fullRestyle(textView)
            }
            fullHighlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        // MARK: Keyboard insets

        // UITextView doesn't adjust for the keyboard on its own; the wrapper
        // ignores SwiftUI keyboard safe-area so we manage insets here.
        func observeKeyboard(for textView: UITextView) {
            self.textView = textView
            let center = NotificationCenter.default
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
            ) { [weak self] note in
                self?.adjustForKeyboard(note)
            })
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.textView?.contentInset.bottom = 0
                self?.textView?.verticalScrollIndicatorInsets.bottom = 0
            })
        }

        private func adjustForKeyboard(_ note: Notification) {
            guard let textView,
                  let window = textView.window,
                  let frameEnd = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            let keyboardInView = textView.convert(frameEnd, from: window)
            let overlap = max(0, textView.bounds.maxY - keyboardInView.minY)
            textView.contentInset.bottom = overlap
            textView.verticalScrollIndicatorInsets.bottom = overlap
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        deinit {
            fullHighlightWork?.cancel()
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
