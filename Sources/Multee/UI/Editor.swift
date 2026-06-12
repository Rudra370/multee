import AppKit
import Highlightr
import Combine

/// One Highlightr (= one JavaScriptCore engine with highlight.js) shared by every editor. Creating
/// one per file was the dominant RAM cost (~50 MB each). Highlighting is stateless per call and runs
/// on the main thread, and all editors use the same theme + shared font, so sharing is safe.
enum SharedHighlightr {
    static let instance: Highlightr = {
        let h = Highlightr()!
        _ = h.setTheme(to: "atom-one-dark")
        return h
    }()
}

/// DEV harness hook: the editor for the currently-active file tab (set by CenterViewController).
enum ActiveEditor { static weak var current: EditorViewController? }

/// NSTextView subclass that intercepts Cmd+S to save.
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Map a file extension to a highlight.js language id.
private func hlLanguage(for path: String) -> String? {
    switch (path as NSString).pathExtension.lowercased() {
    case "py": return "python"
    case "js", "mjs", "cjs", "jsx": return "javascript"
    case "ts", "tsx": return "typescript"
    case "swift": return "swift"
    case "json": return "json"
    case "md", "markdown": return "markdown"
    case "rs": return "rust"
    case "go": return "go"
    case "rb": return "ruby"
    case "java": return "java"
    case "kt": return "kotlin"
    case "c", "h": return "c"
    case "cpp", "cc", "cxx", "hpp": return "cpp"
    case "cs": return "csharp"
    case "php": return "php"
    case "sh", "bash", "zsh": return "bash"
    case "yml", "yaml": return "yaml"
    case "html", "htm": return "xml"
    case "css", "scss", "less": return "css"
    case "toml", "ini": return "ini"
    case "sql": return "sql"
    case "xml": return "xml"
    default: return nil
    }
}

/// A syntax-highlighted file editor (NSTextView + Highlightr's CodeAttributedString). Cmd+S saves;
/// edits flag the tab dirty. Font size tracks Settings live, resizing runs in place (no re-tokenize).
final class EditorViewController: NSViewController, NSTextViewDelegate {
    let path: String          // absolute file path
    private let settings: Settings
    private let onDirty: (Bool) -> Void

    private var textView: CodeTextView!
    private var textStorage: CodeAttributedString!
    private var saved = ""
    private var lastFontSize: Double
    private var cancellables = Set<AnyCancellable>()

    init(path: String, settings: Settings, onDirty: @escaping (Bool) -> Void) {
        self.path = path
        self.settings = settings
        self.onDirty = onDirty
        self.lastFontSize = settings.fontSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let fontSize = settings.fontSize

        let ts = CodeAttributedString(highlightr: SharedHighlightr.instance)   // one shared JS engine
        ts.language = hlLanguage(for: path)
        let highlightr = ts.highlightr
        highlightr.theme.setCodeFont(mono(fontSize))
        let themeBg = highlightr.theme.themeBackgroundColor ?? NSColor(calibratedWhite: 0.118, alpha: 1)
        self.textStorage = ts

        let layoutManager = NSLayoutManager()
        ts.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = CodeTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.backgroundColor = themeBg
        tv.insertionPointColor = NSColor.white
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
        tv.delegate = self

        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        tv.string = content
        saved = content
        tv.onSave = { [weak self] in self?.save() }
        self.textView = tv

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = themeBg
        scroll.documentView = tv
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings.$fontSize.dropFirst().sink { [weak self] in self?.applyFont($0) }.store(in: &cancellables)
    }

    func textDidChange(_ notification: Notification) {
        onDirty(textView.string != saved)
    }

    func save() {
        let content = textView.string
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        saved = content
        onDirty(false)
    }

    /// DEV harness: current editor text (for asserting load/edit/save without pixels).
    var debugText: String { textView?.string ?? "" }
    var isDirty: Bool { (textView?.string ?? "") != saved }
    /// DEV harness: append text (programmatic .string set doesn't fire the delegate, so flag dirty).
    func debugAppend(_ s: String) {
        textView.string += s
        onDirty(textView.string != saved)
    }

    private func applyFont(_ size: Double) {
        guard lastFontSize != size else { return }
        lastFontSize = size
        let f = mono(size)
        textView.font = f
        // Resize runs in place — DON'T re-run highlight.js (re-tokenizing is slow). Only swap each
        // run's font to the new size, preserving bold/italic via the font manager.
        textStorage.highlightr.theme.setCodeFont(f)
        textStorage.beginEditing()
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.font, in: full) { value, range, _ in
            let resized = (value as? NSFont).map { NSFontManager.shared.convert($0, toSize: size) } ?? f
            textStorage.addAttribute(.font, value: resized, range: range)
        }
        textStorage.endEditing()
    }

    private func mono(_ s: Double) -> NSFont { .monospacedSystemFont(ofSize: s, weight: .regular) }
}
