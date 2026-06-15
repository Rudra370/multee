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

        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings.$fontSize.dropFirst().sink { [weak self] in self?.applyFont($0) }.store(in: &cancellables)
    }

    func textDidChange(_ notification: Notification) {
        onDirty(textView.string != saved)
        requestHighlight(debounced: true)
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
        let range = NSRange(location: idx, length: end - idx)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        // Center the target line rather than just barely revealing it.
        if let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = view as? NSScrollView {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let midY = rect.midY + tv.textContainerOrigin.y
            let h = scroll.contentView.bounds.height
            let y = max(0, min(midY - h / 2, tv.bounds.height - h))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        tv.window?.makeFirstResponder(tv)
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
        guard let scroll = view as? NSScrollView else { return }
        let clip = scroll.contentView
        let y = clip.bounds.origin.y + CGFloat(lines) * (lastFontSize + 4)
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
    }
    var isDirty: Bool { (textView?.string ?? "") != saved }
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
