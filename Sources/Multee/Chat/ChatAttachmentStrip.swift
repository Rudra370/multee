import AppKit

/// The images pasted into the message box, as a row of thumbnails above the text (like claude.ai) — the text
/// itself stays plain. Each has a number badge (so "image 2" in your text has something to point at), a ×
/// on hover to take it out, and a click opens it in Quick Look.
final class ChatAttachmentStrip: NSView {
    static let side: CGFloat = 44
    static let gap: CGFloat = 8
    var onRemove: ((Int) -> Void)?
    var onPreview: ((Int) -> Void)?
    private var tiles: [Tile] = []

    override var isFlipped: Bool { true }

    func set(_ images: [NSImage]) {
        while tiles.count < images.count {
            let t = Tile()
            t.onRemove = { [weak self, weak t] in if let self, let t, let i = self.tiles.firstIndex(of: t) { self.onRemove?(i) } }
            t.onPreview = { [weak self, weak t] in if let self, let t, let i = self.tiles.firstIndex(of: t) { self.onPreview?(i) } }
            addSubview(t)
            tiles.append(t)
        }
        while tiles.count > images.count { tiles.removeLast().removeFromSuperview() }
        for (i, (t, image)) in zip(tiles, images).enumerated() { t.set(image, number: i + 1) }
        needsLayout = true
    }

    /// Tiles per row at this width, and the height all of them need — they wrap rather than run off the box.
    private static func perRow(_ width: CGFloat) -> Int { max(1, Int((width + gap) / (side + gap))) }
    func preferredHeight(width: CGFloat) -> CGFloat {
        guard !tiles.isEmpty else { return 0 }
        let rows = CGFloat((tiles.count + Self.perRow(width) - 1) / Self.perRow(width))
        return rows * Self.side + (rows - 1) * Self.gap + 8          // + the space above the text
    }

    override func layout() {
        super.layout()
        let n = Self.perRow(bounds.width)
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: CGFloat(i % n) * (Self.side + Self.gap), y: CGFloat(i / n) * (Self.side + Self.gap),
                             width: Self.side, height: Self.side)
        }
        window?.invalidateCursorRects(for: self)
    }

    var debugTiles: Int { tiles.count }

    /// One thumbnail: the picture filling a rounded square, its number bottom-left, × top-right on hover.
    final class Tile: NSView {
        var onRemove: (() -> Void)?
        var onPreview: (() -> Void)?
        private let picture = CALayer()
        private let badge = Badge()
        private let remove = PointerButton()
        private var hovering = false { didSet { remove.isHidden = !hovering } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
            layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
            picture.contentsGravity = .resizeAspectFill
            layer?.addSublayer(picture)

            addSubview(badge)

            remove.isBordered = false
            remove.bezelStyle = .inline
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove image")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0, alpha: 0.7)])))
            remove.toolTip = "Remove"
            remove.target = self
            remove.action = #selector(removeTapped)
            remove.isHidden = true
            addSubview(remove)
            toolTip = "Click to preview"
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func set(_ image: NSImage, number: Int) {
            picture.contents = image
            badge.number = number
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            picture.frame = bounds
            CATransaction.commit()
            badge.frame = NSRect(x: 4, y: bounds.height - 19, width: badge.number > 9 ? 21 : 15, height: 15)
            remove.frame = NSRect(x: bounds.width - 19, y: 1, width: 18, height: 18)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        // The magnifier over the picture (the × keeps its own hand). Cursor rects are load-bearing; the tracking
        // area's cursorUpdate re-arms it (see CLAUDE.md "Two cursor mechanisms").
        override func resetCursorRects() { addCursorRect(bounds, cursor: .chatPreview) }
        override func cursorUpdate(with event: NSEvent) {
            if remove.isHidden || !remove.frame.contains(convert(event.locationInWindow, from: nil)) { NSCursor.chatPreview.set() }
        }

        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onPreview?() }
        }

        @objc private func removeTapped() { onRemove?() }
    }

    /// The number in a dark circle, drawn centred (a label in a frame this small sits off-centre).
    final class Badge: NSView {
        var number = 1 { didSet { needsDisplay = true; superview?.needsLayout = true } }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0, alpha: 0.65).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()   // a pill past 9
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the tile
    }
}
