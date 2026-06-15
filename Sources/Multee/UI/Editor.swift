import AppKit
import Combine

/// DEV harness hook: the editor for the currently-active file tab (set by CenterViewController).
enum ActiveEditor { static weak var current: EditorViewController? }

/// A content view controller that hosts an editable source editor — directly (the plain-file editor) or
/// embedded behind a Preview/Image toggle (markdown, SVG). Lets `CenterViewController` find the live
/// editor uniformly (active-editor tracking, dev harness) and retarget it in place on rename (so unsaved
/// edits survive) regardless of the viewer wrapping it.
protocol SourceEditing: AnyObject {
    var sourceEditor: EditorViewController? { get }
    /// File renamed/moved while open: redirect saves to the new path, keeping unsaved edits.
    func retarget(to path: String)
}

/// NSTextView subclass that intercepts Cmd+S to save and adds "Format Document" to the right-click menu.
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
    var onFormat: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Format Document", action: #selector(formatFromMenu), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
    @objc private func formatFromMenu() { onFormat?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A syntax-highlighted file editor: a plain `NSTextView`/`NSTextStorage` coloured by our native
/// TextMate highlighter (no JavaScript engine). Cmd+S saves; edits flag the tab dirty and trigger a
/// debounced re-highlight that only repaints colours (text, cursor and undo are untouched). Font size
/// tracks Settings live; resizing swaps each run's font in place (no re-tokenize).
final class EditorViewController: NSViewController, NSTextViewDelegate, SourceEditing {
    var sourceEditor: EditorViewController? { self }
    /// Current editor text (live, including unsaved edits) — used by preview re-render on toggle.
    var text: String { textView?.string ?? "" }

    private(set) var path: String   // absolute file path (mutable: a rename retargets it in place)
    private let settings: Settings
    private let onDirty: (Bool) -> Void

    private var textView: CodeTextView!
    private var scrollView: NSScrollView!
    private var textStorage: NSTextStorage!
    private var lineRuler: LineNumberRuler!
    private var highlighter: TextMateHighlighter?
    private var saved = ""
    private var lastFontSize: Double
    private var cancellables = Set<AnyCancellable>()
    private var rehighlightWork: DispatchWorkItem?
    private var highlightSeq = 0
    /// All tokenizing runs on one shared serial queue: it keeps the UI responsive on large files and
    /// serialises access to the shared (per-language) highlighter, whose regexes compile lazily.
    private static let highlightQueue = DispatchQueue(label: "com.multee.highlight", qos: .userInitiated)

    init(path: String, settings: Settings, onDirty: @escaping (Bool) -> Void) {
        self.path = path
        self.settings = settings
        self.onDirty = onDirty
        self.lastFontSize = settings.fontSize
        self.highlighter = TextMateHighlighter.forPath(path)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let fontSize = settings.fontSize
        let storage = NSTextStorage()
        self.textStorage = storage

        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = CodeTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.backgroundColor = TMTheme.background
        tv.insertionPointColor = .white
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = NSView.AutoresizingMask.width
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = mono(fontSize)
        tv.typingAttributes = [.font: mono(fontSize), .foregroundColor: TMTheme.base]
        tv.delegate = self
        self.textView = tv

        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        textStorage.setAttributedString(NSAttributedString(
            string: content, attributes: [.font: mono(fontSize), .foregroundColor: TMTheme.base]))
        saved = content
        tv.onSave = { [weak self] in self?.save() }
        tv.onFormat = { [weak self] in self?.formatDocument() }
        requestHighlight(debounced: false)   // colours apply off-main; first paint shows plain text instantly

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // Legacy (always-visible) scroller, not the overlay one: the bar stays put instead of
        // appearing only mid-scroll, and it gets its own gutter so the text view's I-beam no longer
        // bleeds under it (the scroller area shows the normal arrow cursor).
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = TMTheme.background
        scroll.documentView = tv

        // Line-number gutter (VS Code-style), drawn as the scroll view's vertical ruler.
        let ruler = LineNumberRuler(scrollView: scroll, textView: tv)
        ruler.font = mono(fontSize)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        ruler.reload()   // build the line index for the just-loaded content
        self.lineRuler = ruler
        self.scrollView = scroll

        // The find bar floats in its own child window (UI/FindBar in a FindPanel), pinned to the editor's
        // top-right (VS Code style) — a separate window has its own cursor-rect domain, so the bar's button
        // cursors don't conflict with the text view's I-beam the way a same-window overlay subview did.
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings.$fontSize.dropFirst().sink { [weak self] in self?.applyFont($0) }.store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if findVisible { positionFindPanel() }   // keep the floating bar pinned through sidebar/split resizes
    }

    func textDidChange(_ notification: Notification) {
        onDirty(textView.string != saved)
        requestHighlight(debounced: true)
        if findBar?.isHidden == false { recomputeMatches() }   // keep find matches/highlights in sync with edits
    }

    func save() {
        // Format-on-save: if enabled and this file has an enabled formatter, format first, then write.
        // Never block the save — formatter errors / not-installed just save the unformatted text (no prompt).
        if settings.formatOnSave, let spec = Formatter.spec(forPath: path), settings.formatterEnabled(spec.id) {
            let text = textView.string, p = path
            EditorViewController.formatQueue.async {
                let outcome = Formatter.format(text: text, path: p)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if case .formatted(let newText) = outcome, self.textView.string == text {
                        self.replacePreservingCursor(with: newText)
                    }
                    self.writeToDisk()
                }
            }
        } else {
            writeToDisk()
        }
    }

    private func writeToDisk() {
        let content = textView.string
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        saved = content
        onDirty(false)
    }

    /// Synchronous, unconditional write — used by the unsaved-changes guard so "Save & Close" / quit always
    /// persists *now*, before the tab or app closes. (format-on-save's async path could otherwise run after
    /// this editor is torn down and silently drop the edits.)
    func saveImmediately() { writeToDisk() }

    /// Make the text view first responder — called when its tab becomes active so you can type / search /
    /// jump without clicking into it first.
    func focusText() { textView?.window?.makeFirstResponder(textView) }

    /// Jump to (and select) a 1-based line, centering it in the viewport — used by the command palette's
    /// `:123` line jump. Clamps to the valid range; no-op on an empty editor.
    func goToLine(_ line: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return }
        var idx = 0, current = 1
        while current < line {
            let r = ns.range(of: "\n", range: NSRange(location: idx, length: ns.length - idx))
            if r.location == NSNotFound { break }
            idx = r.location + 1
            current += 1
        }
        let nl = ns.range(of: "\n", range: NSRange(location: idx, length: ns.length - idx))
        let end = nl.location == NSNotFound ? ns.length : nl.location
        tv.setSelectedRange(NSRange(location: idx, length: end - idx))
        tv.window?.makeFirstResponder(tv)
        centerSelection()
        // Re-center next runloop: a just-opened (or just-focused) editor may not have completed layout /
        // sizing yet, so the first pass can mis-measure. The deferred pass runs against the settled view.
        DispatchQueue.main.async { [weak self] in self?.centerSelection() }
    }

    /// Scroll so the current selection sits vertically centered. Uses `scrollToVisible` with a
    /// viewport-tall rect centered on the line — `NSView` handles the clip's (non-standard, ruler-offset)
    /// coordinate space, which manual `clip.scroll(to:)` got wrong (sending the view past the text).
    /// Forces layout up to the selection first, since `NSLayoutManager` is lazy and an un-laid-out range
    /// mis-measures.
    private func centerSelection() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = scrollView?.contentView else { return }
        let range = tv.selectedRange()
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.y += tv.textContainerOrigin.y
        let h = clip.bounds.height
        tv.scrollToVisible(NSRect(x: 0, y: rect.midY - h / 2, width: 1, height: h))
    }

    // MARK: - Find (UI/FindBar)

    private var findBar: FindBar?
    private var findPanel: FindPanel?      // floating child window hosting the find bar (top-right overlay)
    private var findObservers: [NSObjectProtocol] = []   // reposition on window move/resize
    private var findMatches: [NSRange] = []
    private var findCurrent = -1
    private var findVisible: Bool { findPanel?.isVisible ?? false }
    private static let findHL = NSColor.systemYellow.withAlphaComponent(0.32)
    private static let findHLCurrent = NSColor.systemOrange.withAlphaComponent(0.6)

    /// Show the find bar (⌘F) in its floating panel, seeding it from the current one-line selection.
    func showFind() {
        guard let win = view.window else { return }
        if findBar == nil {
            let bar = FindBar(matchCase: settings.findMatchCase,
                              wholeWord: settings.findWholeWord, regex: settings.findRegex)
            bar.onChange = { [weak self] in self?.findChanged() }
            bar.onNext = { [weak self] in self?.findStep(1) }
            bar.onPrev = { [weak self] in self?.findStep(-1) }
            bar.onClose = { [weak self] in self?.hideFind() }
            bar.onReplace = { [weak self] in self?.replaceCurrent() }
            bar.onReplaceAll = { [weak self] in self?.replaceAll() }
            bar.onResize = { [weak self] in self?.positionFindPanel() }   // replace row toggled → refit
            findBar = bar

            let panel = FindPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = bar
            findPanel = panel
        }
        guard let panel = findPanel else { return }
        if panel.parent == nil { win.addChildWindow(panel, ordered: .above) }
        positionFindPanel()
        let sel = textView.selectedRange()
        if sel.length > 0 {
            let s = (textView.string as NSString).substring(with: sel)
            if !s.contains("\n") { findBar?.setQuery(s) }
        }
        panel.makeKeyAndOrderFront(nil)
        findBar?.focusField()
        observeWindowForReposition(win)
        recomputeMatches()
    }

    func hideFind() {
        if let panel = findPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        removeFindObservers()
        clearFindHighlights()
        findMatches = []; findCurrent = -1
        view.window?.makeKeyAndOrderFront(nil)        // return key to the main window
        view.window?.makeFirstResponder(textView)
    }

    /// Close the find panel if it's open — called when this editor's tab stops being active (so a stray
    /// floating bar doesn't linger over another tab).
    func hideFindIfShown() { if findVisible { hideFind() } }

    /// Size the panel to the bar and pin it to the editor view's top-right (in screen coords).
    private func positionFindPanel() {
        guard let panel = findPanel, let bar = findBar, let win = view.window else { return }
        let size = bar.fittingSize
        panel.setContentSize(size)
        let inScreen = win.convertToScreen(view.convert(view.bounds, to: nil))
        let margin: CGFloat = 12
        panel.setFrameOrigin(NSPoint(x: inScreen.maxX - size.width - margin,
                                     y: inScreen.maxY - size.height - margin))
    }

    private func observeWindowForReposition(_ win: NSWindow) {
        removeFindObservers()
        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            findObservers.append(nc.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                self?.positionFindPanel()
            })
        }
    }
    private func removeFindObservers() {
        findObservers.forEach { NotificationCenter.default.removeObserver($0) }
        findObservers = []
    }

    /// ⌘G / ⌘⇧G — open the bar if closed, else step. (Works from the editor, not just the find field.)
    func findNext() { findVisible ? findStep(1) : showFind() }
    func findPrevious() { findVisible ? findStep(-1) : showFind() }

    /// ⌥⌘F — open find with the Replace row expanded.
    func showReplace() { showFind(); findBar?.expandReplace() }

    /// Replace the current match, then advance (textDidChange re-runs the search → highlights refresh).
    func replaceCurrent() {
        guard let bar = findBar, findMatches.indices.contains(findCurrent) else { return }
        let r = findMatches[findCurrent]
        let replacement = expandedReplacement(for: r, bar: bar)
        if textView.shouldChangeText(in: r, replacementString: replacement) {
            textView.textStorage?.replaceCharacters(in: r, with: replacement)
            textView.didChangeText()
        }
    }

    /// Replace every match in a single undoable edit (reverse order keeps the earlier ranges valid).
    func replaceAll() {
        guard let bar = findBar, !findMatches.isEmpty else { return }
        let ns = textView.string as NSString
        let result = NSMutableString(string: ns)
        for r in findMatches.reversed() {
            result.replaceCharacters(in: r, with: expandedReplacement(for: r, bar: bar))
        }
        let full = NSRange(location: 0, length: ns.length)
        if textView.shouldChangeText(in: full, replacementString: result as String) {
            textView.textStorage?.replaceCharacters(in: full, with: result as String)
            textView.didChangeText()
        }
    }

    /// In regex mode, expand `$1`-style templates against the matched text; otherwise a literal replacement.
    private func expandedReplacement(for range: NSRange, bar: FindBar) -> String {
        guard bar.regex else { return bar.replaceText }
        var opts: NSRegularExpression.Options = []
        if !bar.matchCase { opts.insert(.caseInsensitive) }
        let pattern = bar.wholeWord ? "\\b(?:\(bar.query))\\b" : bar.query
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return bar.replaceText }
        let matched = (textView.string as NSString).substring(with: range)
        return re.stringByReplacingMatches(in: matched, range: NSRange(location: 0, length: (matched as NSString).length),
                                           withTemplate: bar.replaceText)
    }

    /// ⌘E — search for the current selection.
    func useSelectionForFind() {
        showFind()
        let sel = textView.selectedRange()
        if sel.length > 0 {
            findBar?.setQuery((textView.string as NSString).substring(with: sel))
            findChanged()
        }
    }

    private func findChanged() {
        guard let bar = findBar else { return }
        settings.findMatchCase = bar.matchCase   // persist the toggles (remembered across files/launches)
        settings.findWholeWord = bar.wholeWord
        settings.findRegex = bar.regex
        recomputeMatches()
    }

    private func findStep(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findCurrent = (findCurrent + delta + findMatches.count) % findMatches.count
        focusCurrentMatch()
    }

    private func recomputeMatches() {
        guard let bar = findBar, let lm = textView.layoutManager else { return }
        clearFindHighlights()
        findMatches = []
        bar.setInvalid(false)
        let full = textView.string
        let ns = full as NSString
        let q = bar.query
        guard !q.isEmpty else { findCurrent = -1; bar.setCount(current: 0, total: 0); return }

        if bar.regex {
            var opts: NSRegularExpression.Options = []
            if !bar.matchCase { opts.insert(.caseInsensitive) }
            let pattern = bar.wholeWord ? "\\b(?:\(q))\\b" : q
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else {
                bar.setInvalid(true); findCurrent = -1; bar.setCount(current: 0, total: 0); return
            }
            re.enumerateMatches(in: full, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range, r.length > 0 { findMatches.append(r) }
            }
        } else {
            var opts: NSString.CompareOptions = []
            if !bar.matchCase { opts.insert(.caseInsensitive) }
            var from = 0
            while from < ns.length {
                let r = ns.range(of: q, options: opts, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                if !bar.wholeWord || isWholeWord(r, ns) { findMatches.append(r) }
                from = r.location + max(1, r.length)
            }
        }

        if findMatches.isEmpty {
            findCurrent = -1; bar.setCount(current: 0, total: 0)
        } else {
            let caret = textView.selectedRange().location
            findCurrent = findMatches.firstIndex { $0.location >= caret } ?? 0
            focusCurrentMatch()
        }
    }

    /// Repaint every match (yellow) + the current one (orange), select & center it, update the counter.
    private func focusCurrentMatch() {
        guard let lm = textView.layoutManager, let bar = findBar,
              findMatches.indices.contains(findCurrent) else { return }
        lm.removeTemporaryAttribute(.backgroundColor,
            forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        for r in findMatches { lm.addTemporaryAttribute(.backgroundColor, value: Self.findHL, forCharacterRange: r) }
        let r = findMatches[findCurrent]
        lm.addTemporaryAttribute(.backgroundColor, value: Self.findHLCurrent, forCharacterRange: r)
        textView.setSelectedRange(r)
        centerSelection()
        bar.setCount(current: findCurrent + 1, total: findMatches.count)
    }

    private func clearFindHighlights() {
        guard let lm = textView?.layoutManager else { return }
        lm.removeTemporaryAttribute(.backgroundColor,
            forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
    }

    private func isWholeWord(_ r: NSRange, _ s: NSString) -> Bool {
        func word(_ c: unichar) -> Bool {
            guard let u = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "_"
        }
        let before = r.location > 0 ? word(s.character(at: r.location - 1)) : false
        let afterIdx = r.location + r.length
        let after = afterIdx < s.length ? word(s.character(at: afterIdx)) : false
        return !before && !after
    }

    // MARK: - Formatting

    private static let formatQueue = DispatchQueue(label: "com.multee.format", qos: .userInitiated)

    /// Format the current file with its configured formatter (⌘⇧F / right-click). Runs off-main; applies
    /// the result preserving the cursor + a single undo, or surfaces a not-installed / error prompt.
    func formatDocument() {
        let p = path
        if let spec = Formatter.spec(forPath: p), !settings.formatterEnabled(spec.id) {
            FormatterPrompt.disabled(spec); return
        }
        let text = textView.string
        EditorViewController.formatQueue.async {
            let outcome = Formatter.format(text: text, path: p)
            DispatchQueue.main.async { [weak self] in self?.applyFormat(outcome, expecting: text) }
        }
    }

    private func applyFormat(_ outcome: Formatter.Outcome, expecting original: String) {
        // The user may have typed while the formatter ran — don't clobber newer edits.
        guard textView.string == original else { return }
        switch outcome {
        case .formatted(let newText):    replacePreservingCursor(with: newText)
        case .unchanged:                 break
        case .noFormatter(let ext):      FormatterPrompt.noFormatter(ext: ext)
        case .notInstalled(let spec):    FormatterPrompt.notInstalled(spec)
        case .failed(let message):       FormatterPrompt.failed(message)
        }
    }

    /// Replace the whole document with `newText` but only edit the changed middle (common prefix/suffix
    /// preserved), so the cursor stays put and it's one undo step.
    private func replacePreservingCursor(with newText: String) {
        let old = textView.string as NSString
        let new = newText as NSString
        let maxPrefix = min(old.length, new.length)
        var prefix = 0
        while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < (maxPrefix - prefix),
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }

        let replaceRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        guard textView.shouldChangeText(in: replaceRange, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
        textView.didChangeText()   // fires textDidChange → dirty flag, re-highlight, gutter reload

        // Keep the caret sensible: before the edit → unchanged; after it → shift by the length delta;
        // inside it → land at the edit's end.
        let delta = (replacement as NSString).length - replaceRange.length
        var loc = textView.selectedRange().location
        if loc >= NSMaxRange(replaceRange) { loc += delta }
        else if loc > replaceRange.location { loc = replaceRange.location + (replacement as NSString).length }
        textView.setSelectedRange(NSRange(location: max(0, min(loc, new.length)), length: 0))
    }

    /// The file was renamed/moved on disk: redirect saves to the new path and re-pick the syntax
    /// grammar for the (possibly new) extension. Content, cursor, undo, and dirty state are untouched.
    func retarget(to newPath: String) {
        guard newPath != path else { return }
        path = newPath
        highlighter = TextMateHighlighter.forPath(newPath)
        if highlighter == nil {
            // New extension has no grammar — clear stale colours from the old type (requestHighlight
            // early-returns when there's no highlighter, so it won't reset them itself).
            textStorage.addAttribute(.foregroundColor, value: TMTheme.base,
                                     range: NSRange(location: 0, length: textStorage.length))
        } else {
            requestHighlight(debounced: false)
        }
    }

    // MARK: - Highlighting

    /// Tokenize off the main thread and apply the resulting colours back on main. A full-document
    /// re-highlight keeps multi-line regions (strings/comments spanning the edit) correct; running it
    /// off-main means even a large file never blocks typing or scrolling. Edits coalesce via a 150 ms
    /// debounce, and a sequence number drops any pass that a newer edit has superseded.
    private func requestHighlight(debounced: Bool) {
        guard let highlighter else { return }
        highlightSeq += 1
        let seq = highlightSeq
        rehighlightWork?.cancel()
        // Initial open of a small file: tokenize synchronously so it appears already-coloured (no
        // plain-text flash). Safe on main because the grammar's regexes are precompiled. Large files
        // and all edits go off-main below.
        if !debounced, (textView.string as NSString).length <= 20_000 {
            let content = textView.string
            applySpans(highlighter.spans(for: content), expecting: content)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let content = self.textView.string
            EditorViewController.highlightQueue.async {
                let spans = highlighter.spans(for: content)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.highlightSeq == seq else { return }   // a newer edit won
                    self.applySpans(spans, expecting: content)
                }
            }
        }
        rehighlightWork = work
        if debounced { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) }
        else { work.perform() }
    }

    /// Recolour the storage from computed spans (text/selection/undo untouched). Skipped if the text
    /// changed since these spans were computed — a newer pass is already queued to cover it.
    private func applySpans(_ spans: [(NSRange, NSColor)], expecting content: String) {
        let length = textStorage.length
        guard (content as NSString).length == length else { return }
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: TMTheme.base, range: NSRange(location: 0, length: length))
        for (range, color) in spans where NSMaxRange(range) <= length {
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
        }
        textStorage.endEditing()
    }

    private func applyFont(_ size: Double) {
        guard lastFontSize != size else { return }
        lastFontSize = size
        let f = mono(size)
        textView.font = f
        textView.typingAttributes[.font] = f
        lineRuler.font = f   // gutter tracks the editor font size
        // Resize runs in place — DON'T re-tokenize. Only swap each run's font to the new size,
        // preserving bold/italic via the font manager.
        textStorage.beginEditing()
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.font, in: full) { value, range, _ in
            let resized = (value as? NSFont).map { NSFontManager.shared.convert($0, toSize: size) } ?? f
            textStorage.addAttribute(.font, value: resized, range: range)
        }
        textStorage.endEditing()
    }

    private func mono(_ s: Double) -> NSFont { .monospacedSystemFont(ofSize: s, weight: .regular) }

    // MARK: - DEV harness hooks

    /// Current editor text (for asserting load/edit/save without pixels).
    var debugText: String { textView?.string ?? "" }
    /// Scroll the editor down by `lines` (dev harness — to verify the gutter follows the scroll).
    func debugScroll(lines: Int) {
        guard let scroll = scrollView else { return }
        let clip = scroll.contentView
        let y = clip.bounds.origin.y + CGFloat(lines) * (lastFontSize + 4)
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
    }
    var isDirty: Bool { (textView?.string ?? "") != saved }
    var debugIsFocused: Bool { textView?.window?.firstResponder === textView }
    /// Drive the custom find bar (dev harness — ⌘F + typing into the field is HID the harness can't synthesize).
    func debugFind(_ term: String) { showFind(); findBar?.setQuery(term); findChanged() }
    func debugFindToggle(_ which: String) { findBar?.debugToggle(which); findChanged() }
    func debugFindNext() { findNext() }
    func debugReplaceShow() { showReplace() }
    func debugReplaceAll(_ with: String) { findBar?.setReplace(with); replaceAll() }
    func debugReplaceOne(_ with: String) { findBar?.setReplace(with); replaceCurrent() }
    var debugFindCount: Int { findMatches.count }
    var debugFindCurrent: Int { findCurrent }
    /// The currently selected substring (dev harness — to verify a find landed on a match).
    var debugSelectedText: String {
        guard let tv = textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
    /// 1-based line of the caret/selection start (dev harness — to verify `:N` line jumps).
    var debugCaretLine: Int {
        guard let tv = textView else { return 0 }
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        return (ns.substring(to: loc) as NSString).components(separatedBy: "\n").count
    }
    /// Append text (programmatic `.string` set doesn't fire the delegate, so flag dirty + re-highlight).
    func debugAppend(_ s: String) {
        textView.string += s
        onDirty(textView.string != saved)
        lineRuler.reload()   // programmatic `.string` set doesn't post NSText.didChangeNotification
        requestHighlight(debounced: true)
    }
}
