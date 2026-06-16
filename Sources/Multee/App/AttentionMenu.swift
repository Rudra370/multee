import AppKit

/// Custom views for the menu-bar dropdown so it reads like a status panel, not a plain list: a header
/// summary, then clickable session/tab rows (status dot + name + colored status word, with a rounded hover
/// highlight). Footer actions stay standard `NSMenuItem`s (native highlight + action).
enum AttentionMenu {
    static let rowWidth: CGFloat = 256

    static func color(_ s: ClaudeState) -> NSColor {
        switch s {
        case .idle:         return NSColor(white: 0.55, alpha: 1)
        case .working:      return .systemBlue
        case .needs, .done: return .systemOrange
        }
    }
    static func word(_ s: ClaudeState) -> String {
        switch s {
        case .idle:    return "Idle"
        case .working: return "Working"
        case .needs:   return "Needs you"
        case .done:    return "Done"
        }
    }
}

/// Small filled status dot.
final class MenuDot: NSView {
    private let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill() }
}

/// Non-interactive header: "Multee" + a live summary (colored by urgency).
final class AttentionHeaderView: NSView {
    init(summary: String, color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: AttentionMenu.rowWidth, height: 34))
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Multee")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(white: 0.96, alpha: 1)
        let sub = NSTextField(labelWithString: summary)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = color
        sub.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [title, NSView(), sub])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AttentionMenu.rowWidth),
            heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A clickable session (or tab) row: status dot + name + right-aligned status word, rounded hover highlight.
final class AttentionRowView: NSView {
    private let onClick: () -> Void
    private let nameLabel: NSTextField
    private let statusLabel: NSTextField
    private let baseStatusColor: NSColor
    private(set) var hovered = false

    init(title: String, status: ClaudeState, indent: CGFloat, bold: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.baseStatusColor = AttentionMenu.color(status)
        self.nameLabel = NSTextField(labelWithString: title)
        self.statusLabel = NSTextField(labelWithString: AttentionMenu.word(status))
        super.init(frame: NSRect(x: 0, y: 0, width: AttentionMenu.rowWidth, height: 26))
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: bold ? .medium : .regular)
        nameLabel.textColor = NSColor(white: 0.93, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = baseStatusColor
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [MenuDot(baseStatusColor), nameLabel, NSView(), statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AttentionMenu.rowWidth),
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + indent),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func mouseUp(with event: NSEvent) { enclosingMenuItem?.menu?.cancelTracking(); onClick() }

    /// Reflect hover: highlight background + brighten text so the colored status word stays legible on accent.
    func setHover(_ h: Bool) {
        hovered = h
        nameLabel.textColor = h ? .white : NSColor(white: 0.93, alpha: 1)
        statusLabel.textColor = h ? NSColor(white: 1, alpha: 0.92) : baseStatusColor
        needsDisplay = true
    }
}

extension AttentionMenu {
    /// Render a representative dropdown (header + rows, one hovered) to a PNG so the static design can be
    /// eyeballed without opening the menu (hover/click are HID, user-verified).
    static func debugRender(to path: String) {
        func sep() -> NSView { let v = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 1))
            v.wantsLayer = true; v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor; return v }
        let rows: [NSView] = [
            AttentionHeaderView(summary: "1 session needs you", color: .systemOrange),
            sep(),
            AttentionRowView(title: "searchtest", status: .needs, indent: 0, bold: true, onClick: {}),
            { let r = AttentionRowView(title: "multee", status: .working, indent: 0, bold: true, onClick: {}); r.setHover(true); return r }(),
            AttentionRowView(title: "Claude", status: .working, indent: 16, bold: false, onClick: {}),
            AttentionRowView(title: "Claude 2", status: .done, indent: 16, bold: false, onClick: {}),
            AttentionRowView(title: "docs", status: .idle, indent: 0, bold: true, onClick: {}),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 0))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: h)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
