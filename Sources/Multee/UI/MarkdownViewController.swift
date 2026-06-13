import AppKit

/// Viewer for Markdown files (routed here by extension from a `.file` tab). Shows a rendered preview by
/// default with a **Preview / Source** toggle to see the raw text. The preview text view uses an
/// explicit TextKit 1 stack so `NSTextTable` (tables) and image attachments lay out correctly.
final class MarkdownViewController: NSViewController {
    private let path: String
    private var previewScroll: NSScrollView!
    private var sourceScroll: NSScrollView!

    static func handles(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor

        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let baseURL = URL(fileURLWithPath: path).deletingLastPathComponent()

        previewScroll = makePreview(MarkdownRenderer.render(source, baseURL: baseURL))
        sourceScroll = makeSource(source)
        sourceScroll.isHidden = true

        let toggle = PointerSegmentedControl(labels: ["Preview", "Source"], trackingMode: .selectOne,
                                             target: self, action: #selector(modeChanged))
        toggle.selectedSegment = 0
        toggle.controlSize = .small
        toggle.segmentStyle = .rounded
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(toggle)

        root.addSubview(previewScroll)
        root.addSubview(sourceScroll)
        root.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 34),
            toggle.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            toggle.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            previewScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sourceScroll.topAnchor.constraint(equalTo: previewScroll.topAnchor),
            sourceScroll.leadingAnchor.constraint(equalTo: previewScroll.leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: previewScroll.trailingAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: previewScroll.bottomAnchor),
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
        return scrollWrapping(tv)
    }

    private func makeSource(_ source: String) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.string = source
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textColor = NSColor(white: 0.83, alpha: 1)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = NSView.AutoresizingMask.width
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
        sourceScroll.isHidden = !showSource
        previewScroll.isHidden = showSource
    }
}
