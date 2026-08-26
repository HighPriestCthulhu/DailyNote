import SwiftUI
import UIKit

/// Plain UITextView wrapper with live markdown styling, an optional
/// Obsidian-Live-Preview "markup mode", and a pull-down timeline of previous
/// days. TextKit 1; the only sanctioned animation is the timeline reveal.
///
/// TIMELINE MODE: pulling down past a threshold prepends previous days into
/// the same text view — [older days][═══ header ═══][yesterday][═══ today ═══]
/// [today's live text]. `historyBoundary` (UTF-16 offset of today's text)
/// gates all editing; everything before it is read-only. The model only ever
/// sees today's suffix, so saves/cache/sync are untouched by the timeline.
///
/// Performance contract: typing never re-enters SwiftUI. Keystrokes flow
/// UITextView → `onTextChange` (into unobserved model state); this view only
/// re-reads `text` when `generation` changes. Timeline prepends are pure
/// UIKit — they touch no observable state.
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

    // Timeline mode
    let noteIdentity: String
    let noteDate: Date
    let noteTitle: String
    let historyResetToken: Int
    let onHistoryRevealed: () -> Void
    let onHistoryCollapsed: () -> Void
    let loadHistoryBatch: (Date) async -> VaultFileService.HistoryBatch?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func newlineTimestamp(at date: Date = Date()) -> String {
        "\n-[" + timeFormatter.string(from: date) + "] "
    }

    static func dayHeader(for title: String) -> String {
        "═══ " + title + " ═══\n"
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
        let coordinator = context.coordinator
        coordinator.parent = self

        // A different document (day rollover, vault re-pick) re-anchors the
        // timeline; collapse before the plain load below runs.
        if coordinator.lastNoteIdentity != noteIdentity {
            coordinator.lastNoteIdentity = noteIdentity
            coordinator.collapseHistory(textView)
        }

        if coordinator.lastGeneration != generation {
            coordinator.lastGeneration = generation
            if coordinator.historyActive {
                coordinator.swapTodaySuffix(textView, with: text)
            } else {
                let selection = textView.selectedRange
                let wasAtEnd = selection.location >= (textView.text as NSString).length
                textView.text = text
                let length = (text as NSString).length
                // A caret at the end (the capture position) stays at the end when
                // reconciled content arrives; otherwise clamp in place.
                textView.selectedRange = NSRange(location: wasAtEnd ? length : min(selection.location, length),
                                                 length: 0)
                coordinator.fullRestyle(textView)
            }
            coordinator.lastGoodSuffix = text
        }

        if coordinator.lastResetToken != historyResetToken {
            coordinator.lastResetToken = historyResetToken
            coordinator.collapseHistory(textView)
        }

        if coordinator.lastMarkupMode != markupMode {
            coordinator.lastMarkupMode = markupMode
            coordinator.fullRestyle(textView)
        }

        if autoFocus, !coordinator.didInitialFocus {
            coordinator.didInitialFocus = true
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

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reveal-history"),
           !coordinator.didAutoReveal, !text.isEmpty {
            coordinator.didAutoReveal = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak coordinator, weak textView] in
                guard let coordinator, let textView else { return }
                coordinator.debugTriggerReveal(textView)
            }
        }
        #endif
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
        var didAutoReveal = false
        var lastGeneration = Int.min
        var lastMarkupMode: Bool
        var lastResetToken: Int
        var lastNoteIdentity: String
        /// Mirror of the model's last known good today-text, used to recover
        /// if the boundary sentinel check ever fails.
        var lastGoodSuffix = ""
        let highlighter = MarkdownHighlighter()

        // Timeline state — all unobserved, all UTF-16 offsets.
        private(set) var historyActive = false
        private var historyBoundary = 0
        private var boundarySentinel = ""
        private var nextHistoryDate: Date?
        private var reachedHistoryEnd = false
        private var historyKnownEmpty = false
        private var isLoadingBatch = false
        private var isRevealAnimating = false
        private var historyEpoch = 0
        /// Ownership token: only the request that set `isLoadingBatch` may
        /// clear it, so a stale completion can't unlock a newer in-flight load.
        private var loadToken = 0

        private var lastActiveParagraph = NSRange(location: 0, length: 0)
        private weak var textView: UITextView?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var fullHighlightWork: DispatchWorkItem?

        init(_ parent: PlainTextEditor) {
            self.parent = parent
            self.lastMarkupMode = parent.markupMode
            self.lastResetToken = parent.historyResetToken
            self.lastNoteIdentity = parent.noteIdentity
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
                                          activeParagraph: active,
                                          frontmatterOffset: historyBoundary)
            invalidateGlyphs(textView, in: NSRange(location: 0, length: textView.textStorage.length))
        }

        /// Restyle the paragraphs around `range`; in markup mode also
        /// regenerate their glyphs so concealment changes take effect.
        private func restyle(_ textView: UITextView, around range: NSRange, active: NSRange) {
            highlighter.highlightParagraphs(textView.textStorage, around: range,
                                            conceal: parent.markupMode,
                                            activeParagraph: active,
                                            frontmatterOffset: historyBoundary)
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

        // MARK: Selection — read-only guard + active-line reveal

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Zero-length carets may never rest in history: this blocks
            // marked-text (CJK) and dictation, which bypass shouldChangeTextIn.
            // Ranged selections are allowed so history can be copied.
            if historyActive {
                let selection = textView.selectedRange
                if selection.length == 0, selection.location < historyBoundary {
                    textView.selectedRange = NSRange(location: historyBoundary, length: 0)
                    return // re-entrant call lands past the boundary
                }
            }

            guard parent.markupMode else { return }
            let newActive = activeParagraph(textView)
            guard newActive != lastActiveParagraph else { return }
            let ns = textView.text as NSString
            let old = MarkdownHighlighter.clamped(lastActiveParagraph, to: ns.length)
            lastActiveParagraph = newActive
            // Two scoped restyles: re-conceal the departed range, reveal the new one.
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
            // History is immutable: refuse any change that touches it.
            // (Insertion exactly at the boundary is the start of today — legal.)
            if historyActive, range.location < historyBoundary { return false }

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
            let ns = textView.text as NSString

            if historyActive {
                // Sentinel failsafe: today's header must still sit intact just
                // before the boundary. If anything slipped past the guards,
                // recover instead of ever saving a mis-sliced suffix.
                let sentinel = boundarySentinel as NSString
                let ok = historyBoundary >= sentinel.length && ns.length >= historyBoundary
                    && ns.substring(with: NSRange(location: historyBoundary - sentinel.length,
                                                  length: sentinel.length)) == boundarySentinel
                guard ok else {
                    emergencyRestore(textView)
                    return
                }
                let suffix = ns.substring(from: historyBoundary)
                lastGoodSuffix = suffix
                parent.onTextChange(suffix)
            } else {
                lastGoodSuffix = textView.text
                parent.onTextChange(textView.text)
            }

            // Cheap per-keystroke styling: the current paragraph, plus the
            // departed range when the caret crossed a line boundary (Return)
            // or a selection was replaced, so it re-conceals in markup mode.
            let newActive = activeParagraph(textView)
            let old = MarkdownHighlighter.clamped(lastActiveParagraph, to: ns.length)
            if parent.markupMode, old != newActive {
                restyle(textView, around: old, active: newActive)
            }
            lastActiveParagraph = newActive
            restyle(textView, around: newActive, active: newActive)
            textView.typingAttributes = MarkdownHighlighter.baseAttributes

            // Debounced wider pass for multi-line constructs (frontmatter,
            // pasted blocks) — scoped to today's suffix so months of loaded
            // history never join the per-pause restyle.
            fullHighlightWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                if self.historyActive {
                    let length = (textView.text as NSString).length
                    let suffix = NSRange(location: self.historyBoundary,
                                         length: max(0, length - self.historyBoundary))
                    self.restyle(textView, around: suffix, active: self.activeParagraph(textView))
                } else {
                    self.fullRestyle(textView)
                }
            }
            fullHighlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        /// The boundary sentinel failed — history bookkeeping can no longer be
        /// trusted. Drop the timeline and restore the last known good today.
        private func emergencyRestore(_ textView: UITextView) {
            historyEpoch += 1
            historyActive = false
            historyBoundary = 0
            nextHistoryDate = nil
            reachedHistoryEnd = false
            isLoadingBatch = false
            isRevealAnimating = false
            fullHighlightWork?.cancel()
            UIView.performWithoutAnimation {
                textView.text = lastGoodSuffix
                textView.undoManager?.removeAllActions()
                let end = NSRange(location: (lastGoodSuffix as NSString).length, length: 0)
                textView.selectedRange = end
                fullRestyle(textView)
                textView.scrollRangeToVisible(end)
            }
            parent.onHistoryCollapsed()
        }

        // MARK: Timeline — reveal, prepend, collapse

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard let textView = scrollView as? UITextView else { return }
            let rest = -textView.adjustedContentInset.top
            // Checked at finger-lift so a momentum fling that rubber-bands off
            // the top can never trigger a reveal.
            if !historyActive, !historyKnownEmpty, !isLoadingBatch,
               textView.contentOffset.y < rest - 72 {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                startBatchLoad(textView, isFirstReveal: true)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard historyActive, !isLoadingBatch, !reachedHistoryEnd, !isRevealAnimating,
                  nextHistoryDate != nil,
                  let textView = scrollView as? UITextView else { return }
            let rest = -textView.adjustedContentInset.top
            if textView.contentOffset.y < rest + 2 * textView.bounds.height {
                startBatchLoad(textView, isFirstReveal: false)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isRevealAnimating = false
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // A grab mid-glide interrupts the reveal animation without firing
            // scrollViewDidEndScrollingAnimation — clear the flag here so
            // prefetch isn't permanently disabled.
            isRevealAnimating = false
        }

        #if DEBUG
        func debugTriggerReveal(_ textView: UITextView) {
            guard !historyActive else { return }
            startBatchLoad(textView, isFirstReveal: true)
        }
        #endif

        private func startBatchLoad(_ textView: UITextView, isFirstReveal: Bool) {
            guard !isLoadingBatch else { return }
            // Never restructure the document mid-IME-composition: UITextView's
            // marked-text bookkeeping is not shifted by raw storage edits, and
            // a stale marked range would write into history.
            guard textView.markedTextRange == nil else { return }
            let before: Date
            if isFirstReveal {
                guard let yesterday = Calendar.current.date(byAdding: .day, value: -1,
                                                            to: parent.noteDate) else { return }
                before = yesterday
            } else {
                guard let next = nextHistoryDate else { return }
                before = next
            }
            isLoadingBatch = true
            loadToken += 1
            let token = loadToken
            let epoch = historyEpoch
            let load = parent.loadHistoryBatch
            Task { @MainActor [weak self, weak textView] in
                let batch = await load(before)
                guard let self else { return }
                // Only the owner of the in-flight flag may clear it.
                guard self.loadToken == token else { return }
                self.isLoadingBatch = false
                guard let textView, self.historyEpoch == epoch, let batch else { return }
                // Composition started while the batch was loading: drop it;
                // nextHistoryDate is untouched, so the next scroll retries.
                guard textView.markedTextRange == nil else { return }
                self.nextHistoryDate = batch.nextDate
                self.reachedHistoryEnd = batch.reachedEnd
                if batch.days.isEmpty {
                    if isFirstReveal { self.historyKnownEmpty = true } // nothing to reveal
                    return
                }
                self.prepend(batch.days, into: textView, isFirstReveal: isFirstReveal)
            }
        }

        private func prepend(_ days: [VaultFileService.HistoryDay], into textView: UITextView,
                             isFirstReveal: Bool) {
            var chunk = ""
            for day in days {
                chunk += PlainTextEditor.dayHeader(for: day.title) + day.body + "\n\n"
            }
            if isFirstReveal {
                let todayHeader = PlainTextEditor.dayHeader(for: parent.noteTitle)
                chunk += todayHeader
                let headerNS = todayHeader as NSString
                boundarySentinel = headerNS.substring(from: max(0, headerNS.length - 24))
                historyActive = true
                parent.onHistoryRevealed()
            }

            fullHighlightWork?.cancel()
            let chunkLength = (chunk as NSString).length
            UIView.performWithoutAnimation {
                let oldOffset = textView.contentOffset
                // Shift bookkeeping BEFORE the selection moves so the
                // selection-change callback sees consistent state.
                lastActiveParagraph.location += chunkLength
                textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: chunk)
                historyBoundary += chunkLength
                var selection = textView.selectedRange
                selection.location += chunkLength
                textView.selectedRange = selection
                textView.undoManager?.removeAllActions()

                let prepended = NSRange(location: 0, length: chunkLength)
                highlighter.highlightParagraphs(textView.textStorage, around: prepended,
                                                conceal: parent.markupMode,
                                                activeParagraph: lastActiveParagraph,
                                                frontmatterOffset: historyBoundary)
                if parent.markupMode { invalidateGlyphs(textView, in: prepended) }

                // Pixel-stable compensation: measure the prepended height and
                // move the offset by exactly that much.
                let layoutManager = textView.layoutManager
                let glyphs = layoutManager.glyphRange(forCharacterRange: prepended,
                                                      actualCharacterRange: nil)
                layoutManager.ensureLayout(forGlyphRange: glyphs)
                textView.layoutIfNeeded()
                let height = ceil(layoutManager.boundingRect(forGlyphRange: glyphs,
                                                             in: textView.textContainer).maxY)
                // Clamp: direct contentOffset assignment doesn't, and a short
                // document would otherwise park in an invalid offset that
                // jumps on the next layout pass.
                let rest = -textView.adjustedContentInset.top
                let maxOffset = max(rest, textView.contentSize.height
                                          + textView.adjustedContentInset.bottom
                                          - textView.bounds.height)
                let target = min(max(oldOffset.y + height, rest), maxOffset)
                textView.contentOffset = CGPoint(x: oldOffset.x, y: target)
            }

            if isFirstReveal {
                // The one sanctioned animation: glide up to peek the tail of
                // yesterday and its header — never past the top rest position.
                let rest = -textView.adjustedContentInset.top
                let available = textView.contentOffset.y - rest
                let reveal = min(min(160, 0.45 * textView.bounds.height), max(0, available))
                if reveal > 1 {
                    isRevealAnimating = true
                    textView.setContentOffset(CGPoint(x: 0, y: textView.contentOffset.y - reveal),
                                              animated: true)
                }
            }
        }

        func collapseHistory(_ textView: UITextView) {
            // Tracking resets even before the first prepend has landed: an
            // in-flight first-reveal batch for the old note must never prepend
            // onto the new one, and a stale "no history" verdict must not
            // survive a note change.
            historyEpoch += 1
            loadToken += 1
            isLoadingBatch = false
            isRevealAnimating = false
            nextHistoryDate = nil
            reachedHistoryEnd = false
            historyKnownEmpty = false
            guard historyActive else { return }
            fullHighlightWork?.cancel()
            historyActive = false
            let boundary = historyBoundary
            historyBoundary = 0
            boundarySentinel = ""
            UIView.performWithoutAnimation {
                textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: boundary),
                                                       with: "")
                let length = (textView.text as NSString).length
                let shifted = textView.selectedRange.location - boundary
                textView.selectedRange = NSRange(location: min(max(0, shifted), length), length: 0)
                textView.undoManager?.removeAllActions()
                fullRestyle(textView)
                textView.contentOffset = CGPoint(x: 0, y: -textView.adjustedContentInset.top)
            }
            parent.onHistoryCollapsed()
        }

        /// Generation reload while the timeline is open and the note identity
        /// is unchanged (reconcile, external edit, reload menu): swap only
        /// today's suffix, keep the boundary and the reader's scroll position.
        func swapTodaySuffix(_ textView: UITextView, with newText: String) {
            fullHighlightWork?.cancel()
            if textView.markedTextRange != nil {
                // External reload wins over an in-flight IME composition; a
                // stale marked range across a suffix swap would edit history.
                textView.unmarkText()
            }
            let ns = textView.text as NSString
            let oldTotal = ns.length
            let selection = textView.selectedRange
            let wasAtEnd = selection.location >= oldTotal
            let suffixRange = NSRange(location: historyBoundary,
                                      length: max(0, oldTotal - historyBoundary))
            UIView.performWithoutAnimation {
                textView.textStorage.replaceCharacters(in: suffixRange, with: newText)
                let newTotal = (textView.text as NSString).length
                let caret = wasAtEnd ? newTotal
                    : min(max(historyBoundary, selection.location), newTotal)
                textView.selectedRange = NSRange(location: caret, length: 0)
                textView.undoManager?.removeAllActions()
                let newSuffix = NSRange(location: historyBoundary,
                                        length: max(0, newTotal - historyBoundary))
                restyle(textView, around: newSuffix, active: activeParagraph(textView))
            }
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
            // Don't yank a history reader back to the caret on keyboard frame
            // changes; only follow the caret when it's already on screen (or
            // the timeline is closed — the original behavior). Never fight an
            // active drag: interactive keyboard dismissal mid-pull would
            // otherwise cancel the reveal gesture.
            if !(textView.isTracking || textView.isDragging),
               !historyActive || caretIsVisible(textView) {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        private func caretIsVisible(_ textView: UITextView) -> Bool {
            guard let position = textView.selectedTextRange?.end else { return false }
            let caretRect = textView.caretRect(for: position)
            return textView.bounds.inset(by: textView.adjustedContentInset).intersects(caretRect)
        }

        deinit {
            fullHighlightWork?.cancel()
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
