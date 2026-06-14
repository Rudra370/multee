import AppKit

/// Read-only viewer for image files (routed here by extension from a `.file` tab). The image lives in a
/// magnifiable scroll view: fit-to-window on open, pinch / scroll-wheel to zoom and pan, double-click to
/// toggle fit ↔ 100%. A footer shows type / dimensions / size. For SVG (whose render is best-effort —
/// Apple's renderer is a limited subset), a footer **Image / Source** toggle flips to the raw XML.
final class ImageViewController: NSViewController, SourceEditing {
    private var path: String
    private let settings: Settings
    private let onDirty: (Bool) -> Void
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private var sourceScroll: NSView?
    private var editor: EditorViewController?     // SVG only: editable source pane
    private var toggle: PointerSegmentedControl?
    private var nativeSize: NSSize = .zero
    private var didInitialFit = false

    var sourceEditor: EditorViewController? { editor }

    /// Renamed/moved while open: keep the SVG editor's unsaved edits and redirect saves to the new path.
    /// (Only reached for SVG — raster images have no editor and are rebuilt by `CenterViewController`.)
    func retarget(to newPath: String) {
        path = newPath
        editor?.retarget(to: newPath)
    }

    private static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico",
    ]

    private var isSVG: Bool { (path as NSString).pathExtension.lowercased() == "svg" }

    /// Raster types are handled by extension. SVG is best-effort: only if `NSImage` can actually render
    /// it on this macOS — otherwise `handles` returns false and the file opens in the text editor (its
    /// SVG source), which beats a blank render.
    static func handles(_ path: String?) -> Bool {
        guard let path else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if rasterExtensions.contains(ext) { return true }
        if ext == "svg" { return NSImage(contentsOfFile: path)?.isValid == true }
        return false
    }

    init(path: String, settings: Settings, onDirty: @escaping (Bool) -> Void) {
        self.path = path
        self.settings = settings
        self.onDirty = onDirty
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor

        let image = NSImage(contentsOfFile: path)
        nativeSize = Self.pixelSize(of: image)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: nativeSize == .zero ? NSSize(width: 240, height: 140) : nativeSize)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.contentView = CenteringClipView()      // centre the image when smaller than the viewport
        scrollView.documentView = imageView

        // Bottom bar: metadata (left) + an Image/Source toggle (right, SVG only).
        let footer = NSTextField(labelWithString: Self.metadata(path: path, image: image))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = NSColor(white: 0.5, alpha: 1)
        let bottomBar = NSStackView(views: [footer, NSView()])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -6),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root

        if isSVG { addSourceViewAndToggle(into: root, bottomBar: bottomBar) }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
    }

    /// SVG only: an editable source pane (the real editor, hidden initially) + a footer Image/Source
    /// toggle. Editing the XML and switching back to Image re-renders the preview live.
    private func addSourceViewAndToggle(into root: NSView, bottomBar: NSStackView) {
        let editor = EditorViewController(path: path, settings: settings, onDirty: onDirty)
        self.editor = editor
        addChild(editor)
        let source = editor.view
        source.translatesAutoresizingMaskIntoConstraints = false
        source.isHidden = true
        root.addSubview(source)
        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: scrollView.topAnchor),
            source.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            source.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            source.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        sourceScroll = source

        let toggle = PointerSegmentedControl(labels: ["Image", "Source"], trackingMode: .selectOne, target: self,
                                             action: #selector(modeChanged))
        toggle.selectedSegment = 0
        toggle.controlSize = .small
        toggle.segmentStyle = .rounded
        bottomBar.addArrangedSubview(toggle)
        self.toggle = toggle
    }

    /// Dev-harness hook: flip Image/Source (so the editable source + image re-render are testable).
    func debugSetSourceVisible(_ visible: Bool) {
        guard let toggle else { return }
        toggle.selectedSegment = visible ? 1 : 0
        modeChanged(toggle)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let showSource = sender.selectedSegment == 1
        if !showSource, let editor {   // returning to Image: re-render from the edited SVG source
            if let img = NSImage(data: Data(editor.text.utf8)), img.isValid {
                imageView.image = img
                nativeSize = Self.pixelSize(of: img)
            }
        }
        sourceScroll?.isHidden = !showSource
        scrollView.isHidden = showSource
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Fit the image to the window once, on first real layout.
        guard !didInitialFit, nativeSize != .zero, view.bounds.width > 1 else { return }
        didInitialFit = true
        let fit = fitMagnification()
        scrollView.minMagnification = min(fit, 1) * 0.25
        scrollView.maxMagnification = max(1, fit) * 8
        scrollView.magnification = min(fit, 1)   // fit big images; show small ones at 100%, centred
    }

    /// Magnification that makes the whole image fit the viewport (never upscaling past native size here).
    private func fitMagnification() -> CGFloat {
        let viewport = scrollView.contentView.frame.size
        guard nativeSize.width > 0, nativeSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / nativeSize.width, viewport.height / nativeSize.height)
    }

    /// Double-click toggles between fit-to-window and 100%.
    @objc private func toggleZoom() {
        let fit = min(fitMagnification(), 1)
        let target: CGFloat = abs(scrollView.magnification - 1) < 0.01 ? fit : 1
        scrollView.animator().magnification = target
    }

    private static func pixelSize(of image: NSImage?) -> NSSize {
        guard let image else { return .zero }
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size   // vector (SVG) → point size
    }

    private static func metadata(path: String, image: NSImage?) -> String {
        guard let image else { return "Couldn't load image" }
        var parts: [String] = []
        let ext = (path as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        let px = pixelSize(of: image)
        if px.width > 0 { parts.append("\(Int(px.width))×\(Int(px.height))") }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Clip view that keeps the document centred when it's smaller than the viewport, so a zoomed-out or
/// small image sits in the middle instead of pinned to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
