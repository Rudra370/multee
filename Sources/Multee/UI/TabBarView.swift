import AppKit

/// The tab strip above the workspace content. Rebuilt from the active session on change.
final class TabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNewClaude: ((String) -> Void)?   // arg string ("" / "--continue" / …)
    var onNewTerminal: (() -> Void)?

    private let chips = NSStackView()
    private let addButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        chips.orientation = .horizontal
        chips.spacing = 4
        chips.alignment = .centerY

        addButton.title = "+"
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.font = .systemFont(ofSize: 16, weight: .medium)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = "New tab"
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        let outer = NSStackView(views: [chips, addButton, NSView()])
        outer.orientation = .horizontal
        outer.spacing = 6
        outer.alignment = .centerY
        outer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    @objc private func addClicked() {
        let menu = NSMenu()
        let presets: [(String, String)] = [
            ("New Claude", ""),
            ("New Claude — continue", "--continue"),
            ("New Claude — resume", "--resume"),
            ("New Claude — skip permissions", "--dangerously-skip-permissions"),
        ]
        for (title, args) in presets {
            let item = NSMenuItem(title: title, action: #selector(newClaude(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = args
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let term = NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "")
        term.target = self
        menu.addItem(term)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 2), in: addButton)
    }

    @objc private func newClaude(_ sender: NSMenuItem) { onNewClaude?(sender.representedObject as? String ?? "") }
    @objc private func newTerminal() { onNewTerminal?() }
}

/// One tab chip: kind indicator, title, optional dirty dot, close button. Active chip is highlighted.
final class TabChipView: NSView {
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

        let indicator: NSView
        if kind == .claude {
            indicator = StatusDot(state: status)
        } else {
            let glyph = NSTextField(labelWithString: Self.glyph(for: kind))
            glyph.font = .systemFont(ofSize: 11)
            glyph.textColor = .secondaryLabelColor
            indicator = glyph
        }

        let titleButton = NSButton(title: (dirty ? "● " : "") + title, target: self, action: #selector(select))
        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.alignment = .left
        titleButton.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        titleButton.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        titleButton.setButtonType(.momentaryChange)
        titleButton.lineBreakMode = .byTruncatingTail

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 10)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close tab"
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
