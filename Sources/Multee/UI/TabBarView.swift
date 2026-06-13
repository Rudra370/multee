import AppKit

extension NSPasteboard.PasteboardType {
    static let multeeTab = NSPasteboard.PasteboardType("com.multee.tab")
}

/// The tab strip above the workspace content: tab chips on the left, and new-Claude (✦) + args menu
/// (▾) + new-terminal buttons on the right. Rebuilt from the active session on change. Chips are
/// drag-reorderable (intra-strip) — the drop reorders via `Session.moveTab`.
final class TabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNewClaude: ((String) -> Void)?   // arg string ("" / "--continue" / …)
    var onNewTerminal: (() -> Void)?
    /// Reorder: move `dragged` to just before `beforeID` (nil = move to the end).
    var onReorder: ((_ dragged: String, _ beforeID: String?) -> Void)?

    private let chips = NSStackView()
    private let dropIndicator = NSView()   // vertical insertion line shown while dragging a chip

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

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        addSubview(dropIndicator)   // floats above the chips while dragging
        registerForDraggedTypes([.multeeTab])
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
                tabID: tab.id,
                title: tab.title,
                kind: tab.kind,
                status: session.tabStatus[tab.id] ?? .idle,
                dirty: tab.dirty,
                isActive: tab.id == activeTabID,
                copyPaths: Self.copyPaths(for: tab, repo: session.url),
                onSelect: { [weak self] in self?.onSelect?(tab.id) },
                onClose: { [weak self] in self?.onClose?(tab.id) }
            )
            chips.addArrangedSubview(chip)
        }
    }

    /// Absolute + repo-relative path for a file tab (nil for non-file tabs). `Tab.path` is absolute;
    /// relative strips the repo prefix (a file outside the repo keeps its absolute path as "relative").
    static func copyPaths(for tab: Tab, repo: String) -> (absolute: String, relative: String)? {
        guard tab.kind == .file, let abs = tab.path else { return nil }
        let prefix = repo.hasSuffix("/") ? repo : repo + "/"
        let rel = abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : abs
        return (abs, rel)
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

    // MARK: - Drag reorder (drop target)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { showDrop(sender); return .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { showDrop(sender); return .move }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndicator.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropIndicator.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard let dragged = sender.draggingPasteboard.string(forType: .multeeTab) else { return false }
        let (beforeID, _) = insertionPoint(at: sender.draggingLocation)
        if beforeID != dragged { onReorder?(dragged, beforeID) }
        return true
    }

    private func showDrop(_ sender: NSDraggingInfo) {
        let (_, x) = insertionPoint(at: sender.draggingLocation)
        dropIndicator.frame = NSRect(x: x - 1, y: 5, width: 2, height: max(0, bounds.height - 11))
        dropIndicator.isHidden = false
    }

    /// For a drop at `windowPoint`, return the chip id to insert before (nil = append) and the x where
    /// the insertion line should draw.
    private func insertionPoint(at windowPoint: NSPoint) -> (String?, CGFloat) {
        let p = convert(windowPoint, from: nil)
        let chipViews = chips.arrangedSubviews.compactMap { $0 as? TabChipView }
        for chip in chipViews {
            let f = chip.convert(chip.bounds, to: self)
            if p.x < f.midX { return (chip.tabID, f.minX - 2) }
        }
        let endX = chipViews.last.map { $0.convert($0.bounds, to: self).maxX + 2 } ?? 8
        return (nil, endX)
    }
}

/// One tab chip: kind indicator, title, optional dirty dot, close button. The whole chip (except the
/// close button) is click-to-select and drag-to-reorder. Active chip is highlighted.
final class TabChipView: PointerView, NSDraggingSource {
    let tabID: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let copyPaths: (absolute: String, relative: String)?   // file tabs only → right-click copy
    private let closeButton = PointerButton()
    private var mouseDownAt: NSPoint = .zero
    private var didDrag = false

    init(tabID: String, title: String, kind: TabKind, status: ClaudeState, dirty: Bool, isActive: Bool,
         copyPaths: (absolute: String, relative: String)? = nil,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tabID = tabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.copyPaths = copyPaths
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

        // Title is a plain label (not a button) so the whole chip can be dragged; clicks are handled
        // by the chip's own mouse events (see hitTest / mouseUp).
        let titleLabel = NSTextField(labelWithString: (dirty ? "● " : "") + title)
        titleLabel.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close tab"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [indicator, titleLabel, closeButton])
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
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
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

    /// Route all clicks/drags to the chip itself, except the close button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? closeButton : self
    }

    // Click = select; drag past a small threshold = begin a reorder drag.
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownAt.x, dy = event.locationInWindow.y - mouseDownAt.y
        if (dx * dx + dy * dy) > 16 { didDrag = true; beginReorderDrag(event) }   // ~4pt
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag { onSelect() }
    }

    private func beginReorderDrag(_ event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(tabID, forType: .multeeTab)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    // Right-click on a file tab → copy its path. Other tab kinds have no menu (yet).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard copyPaths != nil else { return nil }
        let menu = NSMenu()
        for (title, sel) in [("Copy Path", #selector(copyAbsolute)), ("Copy Relative Path", #selector(copyRelative))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc private func copyAbsolute() { if let p = copyPaths?.absolute { Clipboard.copy(p) } }
    @objc private func copyRelative() { if let p = copyPaths?.relative { Clipboard.copy(p) } }

    @objc private func closeTapped() { onClose() }
}
