import AppKit

/// The tab strip above the workspace content: tab chips on the left, and new-Claude (✦) + args menu
/// (▾) + new-terminal buttons on the right. Rebuilt from the active session on change.
final class TabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNewClaude: ((String) -> Void)?   // arg string ("" / "--continue" / …)
    var onNewTerminal: (() -> Void)?

    private let chips = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        chips.orientation = .horizontal
        chips.spacing = 4
        chips.alignment = .centerY

        let newClaude = iconButton("sparkles", "New Claude session", #selector(newClaudeDefault))
        let argsMenu = iconButton("chevron.down", "New Claude with arguments…", #selector(argsMenuTapped), size: 9)
        let newTerm = iconButton("terminal", "New terminal", #selector(newTerminal))
        let rightButtons = NSStackView(views: [newClaude, argsMenu, newTerm])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = 4
        rightButtons.setContentHuggingPriority(.required, for: .horizontal)

        let outer = NSStackView(views: [chips, NSView(), rightButtons])
        outer.orientation = .horizontal
        outer.spacing = 6
        outer.alignment = .centerY
        outer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // bottom divider
        let div = NSView(); div.wantsLayer = true; div.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        div.translatesAutoresizingMaskIntoConstraints = false
        addSubview(div)
        NSLayoutConstraint.activate([
            div.leadingAnchor.constraint(equalTo: leadingAnchor),
            div.trailingAnchor.constraint(equalTo: trailingAnchor),
            div.bottomAnchor.constraint(equalTo: bottomAnchor),
            div.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat = 12) -> PointerButton {
        let b = PointerButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = NSColor(white: 0.7, alpha: 1)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    func render(session: Session?, activeTabID: String) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let session else { return }
        for tab in session.tabs {
            let chip = TabChipView(
                title: tab.title,
                kind: tab.kind,
                status: session.tabStatus[tab.id] ?? .idle,
                dirty: tab.dirty,
                isActive: tab.id == activeTabID,
                onSelect: { [weak self] in self?.onSelect?(tab.id) },
                onClose: { [weak self] in self?.onClose?(tab.id) }
            )
            chips.addArrangedSubview(chip)
        }
    }

    @objc private func newClaudeDefault() { onNewClaude?("") }
    @objc private func newTerminal() { onNewTerminal?() }

    @objc private func argsMenuTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let presets: [(String, String)] = [
            ("Default", ""),
            ("Continue (--continue)", "--continue"),
            ("Resume (--resume)", "--resume"),
            ("Skip permissions (--dangerously-skip-permissions)", "--dangerously-skip-permissions"),
        ]
        for (title, args) in presets {
            let item = NSMenuItem(title: title, action: #selector(newClaudeArgs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = args
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func newClaudeArgs(_ sender: NSMenuItem) { onNewClaude?(sender.representedObject as? String ?? "") }
}

/// One tab chip: kind indicator, title, optional dirty dot, close button. Active chip is highlighted.
final class TabChipView: PointerView {
    private let onSelect: () -> Void
    private let onClose: () -> Void

    init(title: String, kind: TabKind, status: ClaudeState, dirty: Bool, isActive: Bool,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (isActive ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.03)).cgColor
        toolTip = title

        let indicator: NSView
        if kind == .claude {
            indicator = StatusDot(state: status)
        } else {
            let glyph = NSTextField(labelWithString: Self.glyph(for: kind))
            glyph.font = .systemFont(ofSize: 11)
            glyph.textColor = .secondaryLabelColor
            indicator = glyph
        }

        let titleButton = PointerButton()
        titleButton.title = (dirty ? "● " : "") + title
        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.alignment = .left
        titleButton.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        titleButton.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        titleButton.setButtonType(.momentaryChange)
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.target = self
        titleButton.action = #selector(select)

        let close = PointerButton()
        close.title = "✕"
        close.isBordered = false
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 10)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close tab"
        close.target = self
        close.action = #selector(closeTapped)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [indicator, titleButton, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func glyph(for kind: TabKind) -> String {
        switch kind {
        case .terminal: return "❯"
        case .file:     return "✎"
        case .diff:     return "±"
        case .claude:   return "✦"
        }
    }

    @objc private func select() { onSelect() }
    @objc private func closeTapped() { onClose() }
}
