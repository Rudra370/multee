import AppKit

/// Read-only viewer for image files (routed here by extension from a `.file` tab). The image lives in a
/// magnifiable scroll view: fit-to-window on open, pinch / scroll-wheel to zoom and pan, double-click to
/// toggle fit ↔ 100%. A footer shows type / dimensions / size. For SVG (whose render is best-effort —
/// Apple's renderer is a limited subset), a footer **Image / Source** toggle flips to the raw XML.
final class ImageViewController: NSViewController {
    private let path: String
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private var sourceScroll: NSScrollView?
    private var nativeSize: NSSize = .zero
    private var didInitialFit = false

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

    /// SVG only: a read-only source text view (hidden initially) + a footer Image/Source toggle.
    private func addSourceViewAndToggle(into root: NSView, bottomBar: NSStackView) {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(white: 0.83, alpha: 1)
        textView.string = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.isHidden = true
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        sourceScroll = scroll

        let toggle = PointerSegmentedControl(labels: ["Image", "Source"], trackingMode: .selectOne, target: self,
                                             action: #selector(modeChanged))
        toggle.selectedSegment = 0
        toggle.controlSize = .small
        toggle.segmentStyle = .rounded
        bottomBar.addArrangedSubview(toggle)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let showSource = sender.selectedSegment == 1
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
