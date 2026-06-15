import AppKit

/// Viewer/editor for Markdown files (routed here by extension from a `.file` tab). Shows a rendered
/// preview by default with a **Preview / Source** toggle; Source is the real editor (editable,
/// syntax-highlighted, Cmd+S save, dirty dot, line numbers). Switching back to Preview re-renders live
/// from the editor's current text, so edits show immediately — saved or not. The preview text view uses
/// an explicit TextKit 1 stack so `NSTextTable` (tables) and image attachments lay out correctly.
final class MarkdownViewController: NSViewController, SourceEditing {
    private var path: String
    private var baseURL: URL
    private let editor: EditorViewController
    private var previewScroll: NSScrollView!
    private var previewTextView: NSTextView!
    private var sourceScroll: NSView!
    private var toggle: PointerSegmentedControl!

    var sourceEditor: EditorViewController? { editor }

    /// Renamed/moved while open: keep the editor's unsaved edits, redirect saves, and update `baseURL`
    /// so the live preview resolves relative image paths against the new location.
    func retarget(to newPath: String) {
        path = newPath
        baseURL = URL(fileURLWithPath: newPath).deletingLastPathComponent()
        editor.retarget(to: newPath)
    }

    static func handles(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    init(path: String, settings: Settings, onDirty: @escaping (Bool) -> Void) {
        self.path = path
        self.baseURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        self.editor = EditorViewController(path: path, settings: settings, onDirty: onDirty)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor

        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        previewScroll = makePreview(MarkdownRenderer.render(source, baseURL: baseURL))
        addChild(editor)
        sourceScroll = editor.view              // the editor IS the editable source pane
        sourceScroll.isHidden = true

        toggle = PointerSegmentedControl(labels: ["Preview", "Source"], trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        toggle.selectedSegment = 0
        toggle.controlSize = .small
        toggle.segmentStyle = .rounded

        // Toggle sits at the bottom-right (a leading spacer pushes it over), matching the SVG viewer's
        // Image/Source bar for consistency.
        let bottomBar = NSStackView(views: [NSView(), toggle])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        sourceScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewScroll)
        root.addSubview(sourceScroll)
        root.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            previewScroll.topAnchor.constraint(equalTo: root.topAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -6),
            sourceScroll.topAnchor.constraint(equalTo: previewScroll.topAnchor),
            sourceScroll.leadingAnchor.constraint(equalTo: previewScroll.leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: previewScroll.trailingAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: previewScroll.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root
    }

    /// Rendered preview — explicit TextKit 1 stack (so NSTextTable / attachments render), read-only.
    private func makePreview(_ rendered: NSAttributedString) -> NSScrollView {
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        // Start with a real width — NSTextBlock/NSTextTable lay out against the container width, and a
        // .zero initial frame makes them collapse (one char per line). The scroll view resizes it after.
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textColor = NSColor(white: 0.85, alpha: 1)
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = NSView.AutoresizingMask.width
        tv.linkTextAttributes = [NSAttributedString.Key.foregroundColor: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.96, alpha: 1),
                                 NSAttributedString.Key.cursor: NSCursor.pointingHand]
        previewTextView = tv
        return scrollWrapping(tv)
    }

    private func scrollWrapping(_ tv: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tv
        return scroll
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let showSource = sender.selectedSegment == 1
        if !showSource {   // returning to Preview: re-render live from the editor's current text
            previewTextView.textStorage?.setAttributedString(MarkdownRenderer.render(editor.text, baseURL: baseURL))
        }
        sourceScroll.isHidden = !showSource
        previewScroll.isHidden = showSource
    }

    /// Show the Preview (false) or the editable Source (true) — used by "open at line" from search and the harness.
    func setSourceVisible(_ visible: Bool) { toggle.selectedSegment = visible ? 1 : 0; modeChanged(toggle) }
}
