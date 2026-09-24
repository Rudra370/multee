import AppKit

/// The jump rail: one thin line per message you sent, evenly spaced down the transcript's left edge, the one
/// you're reading brighter. Hovering opens `ChatJumpList` over the chat; clicking a line (or a list row)
/// scrolls to that message. The transcript owns both and does the scrolling.
final class ChatJumpRail: NSView {
    static let width: CGFloat = 16
    static let maxSpacing: CGFloat = 8

    private(set) var count = 0
    private(set) var current: Int?
    var onJump: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    /// Line spacing for `count` lines in `height` points — even, squeezed when they don't fit.
    static func spacing(count: Int, height: CGFloat) -> CGFloat {
        count > 0 ? min(maxSpacing, height / CGFloat(count)) : maxSpacing
    }

    func set(count: Int, current: Int?) {
        guard count != self.count || current != self.current else { return }
        self.count = count
        self.current = current
        needsDisplay = true
    }

    private var spacing: CGFloat { count > 0 ? (bounds.height - 8) / CGFloat(count) : 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let s = spacing
        let thick: CGFloat = s >= 4 ? 2 : 1
        for i in 0..<count {
            let on = i == current
            (on ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.38, alpha: 1)).setFill()
            let w: CGFloat = on ? 12 : 8
            let y = 4 + s * (CGFloat(i) + 0.5) - thick / 2
            NSBezierPath(roundedRect: NSRect(x: 3, y: y, width: w, height: thick), xRadius: thick / 2, yRadius: thick / 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard count > 0, spacing > 0 else { return }
        let y = convert(event.locationInWindow, from: nil).y - 4
        onJump?(min(count - 1, max(0, Int(y / spacing))))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The list the rail opens: a one-line preview of each message you sent, oldest on top, newest at the bottom
/// level with the rail, the one you're reading highlighted. Covers the transcript's full height on a slightly
/// see-through background; built when it opens, not kept in sync while hidden.
final class ChatJumpList: NSView {
    static let maxWidth: CGFloat = 380

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var rows: [Row] = []
    private var rowHeight: CGFloat = 26
    var onJump: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private(set) var selected: Int?                 // keyboard selection (⌘J-opened); nil when opened by hover
    weak var returnFocus: NSResponder?              // who had focus before ⌘J — gets it back on close

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        addSubview(scroll)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Fill with `previews` (oldest first), stacked up from `bottomInset` above the bottom edge.
    func show(_ previews: [String], current: Int?, fontSize: CGFloat, bottomInset: CGFloat) {
        rows.forEach { $0.removeFromSuperview() }
        selected = nil
        rowHeight = max(26, ceil(fontSize * 2))
        rows = previews.enumerated().map { i, text in
            let r = Row(text: text, current: i == current, fontSize: fontSize)
            r.onClick = { [weak self] in self?.onJump?(i) }
            doc.addSubview(r)
            return r
        }
        scroll.frame = NSRect(x: 0, y: bottomInset, width: bounds.width, height: max(0, bounds.height - bottomInset - 8))
        let w = scroll.contentSize.width
        let listH = CGFloat(rows.count) * rowHeight
        let docH = max(listH, scroll.contentSize.height)
        doc.frame = NSRect(x: 0, y: 0, width: w, height: docH)
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 4, y: docH - listH + CGFloat(i) * rowHeight, width: w - 8, height: rowHeight)
        }
        // Open on the message you're reading.
        let focus = current ?? rows.count - 1
        if focus >= 0 { doc.scrollToVisible(rows[focus].frame.insetBy(dx: 0, dy: -rowHeight * 2)) }
    }

    var previews: [String] { rows.map(\.label.stringValue) }

    // MARK: Keyboard (⌘J-opened)

    override var acceptsFirstResponder: Bool { isOpen }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let n = min(max(0, i), rows.count - 1)
        if let old = selected, rows.indices.contains(old) { rows[old].isSelected = false }
        selected = n
        rows[n].isSelected = true
        doc.scrollToVisible(rows[n].frame.insetBy(dx: 0, dy: -rowHeight))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: select((selected ?? rows.count) - 1)                    // ↑
        case 125: select((selected ?? -1) + 1)                            // ↓
        case 115: select(0)                                              // home
        case 119: select(rows.count - 1)                                 // end
        case 36, 76: if let s = selected { onJump?(s) } else { onClose?() }   // ⏎ / keypad enter
        case 53: onClose?()                                              // esc
        default: super.keyDown(with: event)
        }
    }

    // Focus moved elsewhere (a click in the chat or the input): the keyboard session is over.
    override func resignFirstResponder() -> Bool {
        if isOpen { DispatchQueue.main.async { [weak self] in if self?.window?.firstResponder !== self { self?.onClose?() } } }
        return true
    }
    /// DEV: the running open/close animation — opacity from → to.
    var debugFade: String {
        guard let a = layer?.animation(forKey: "fade") else { return "" }
        let fade = (a as? CABasicAnimation) ?? (a as? CAAnimationGroup)?.animations?.first as? CABasicAnimation
        return "\(fade?.fromValue ?? "?")→\(fade?.toValue ?? "model")"
    }

    /// Open (true from `present` until `dismiss` starts — the fade-out doesn't count, so the cursor and hover
    /// logic never wait on it).
    private(set) var isOpen = false
    private var fadeToken = 0

    /// Fade in while sliding a few points out from the rail.
    func present() {
        isOpen = true
        fadeToken += 1
        // From nothing — or, reopened mid-fade-out, from where that fade got to (a hidden layer still reads 1).
        let from: Float = isHidden ? 0 : (layer?.presentation()?.opacity ?? 1)
        isHidden = false
        guard let layer else { return }
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 1
        guard !Motion.reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = CATransform3DMakeTranslation(-10, 0, 0)
        slide.toValue = CATransform3DIdentity
        let g = CAAnimationGroup()
        g.animations = [fade, slide]
        g.duration = 0.14
        g.timingFunction = Motion.easeOut
        layer.add(g, forKey: "fade")
    }

    /// Fade out quickly, then hide — unless it was opened again meanwhile.
    func dismiss() {
        isOpen = false
        fadeToken += 1
        let token = fadeToken
        guard let layer, !Motion.reduceMotion else { isHidden = true; return }
        let from = layer.presentation()?.opacity ?? 1
        layer.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.fadeToken == token else { return }
            self.isHidden = true
            self.layer?.opacity = 1
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = 0.08
        fade.timingFunction = Motion.easeIn
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { if isOpen { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { if isOpen { onHover?(false) } }
    // Fading out: clicks pass through to the chat instead of landing on a list that's going away.
    override func hitTest(_ point: NSPoint) -> NSView? { isOpen ? super.hitTest(point) : nil }
    // The empty space above the rows: a plain arrow (the rows claim the hand over themselves).
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) {}         // don't fall through to the chat

    /// One preview row: highlights on hover, bold white when it's the message you're reading.
    final class Row: PointerView {
        let label = NSTextField(labelWithString: "")
        var onClick: (() -> Void)?
        private let isCurrent: Bool
        private var hovered = false
        var isSelected = false { didSet { setHighlight(hovered) } }

        init(text: String, current: Bool, fontSize: CGFloat) {
            isCurrent = current
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 5
            label.stringValue = text
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.font = .systemFont(ofSize: fontSize, weight: current ? .semibold : .regular)
            label.textColor = current ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.72, alpha: 1)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setHighlight(false)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        // The label is display-only: without this the click and the cursor land on it, not the row.
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

        private func setHighlight(_ on: Bool) {
            hovered = on
            label.textColor = isCurrent || isSelected ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.72, alpha: 1)
            layer?.backgroundColor = isSelected ? NSColor(srgbRed: 0.24, green: 0.36, blue: 0.58, alpha: 0.9).cgColor
                : on ? NSColor(white: 1, alpha: 0.1).cgColor
                : isCurrent ? NSColor(white: 1, alpha: 0.06).cgColor : NSColor.clear.cgColor
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) }.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { setHighlight(true) }
        override func mouseExited(with event: NSEvent) { setHighlight(false) }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
