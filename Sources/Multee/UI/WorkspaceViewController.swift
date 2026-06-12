import AppKit
import Combine

/// Root layout: a horizontal split with the workspace (center) on the left and the sidebar
/// (files / sessions) on the right. NSSplitViewController gives live, persistent, correctly-cursored
/// resizing for free — the thing SwiftUI's HSplitView couldn't do cleanly.
final class WorkspaceViewController: NSSplitViewController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true                 // vertical divider → side-by-side
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MulteeMainSplit"

        let center = NSSplitViewItem(viewController: CenterViewController(model: model))
        center.minimumThickness = 480
        center.holdingPriority = .defaultLow        // center flexes when the window resizes

        let sidebar = NSSplitViewItem(viewController: SidebarViewController(model: model))
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 560
        sidebar.canCollapse = false
        sidebar.holdingPriority = .defaultHigh       // sidebar keeps its width

        addSplitViewItem(center)
        addSplitViewItem(sidebar)
    }
}

// MARK: - Center (workspace)

/// Phase 0: shows the active session / tab summary or an empty state. The tab bar + tab content
/// land in Phase 1.
final class CenterViewController: NSViewController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var activeSessionObserver: AnyCancellable?
    private let label = NSTextField(labelWithString: "")

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        label.maximumNumberOfLines = 0
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -24),
        ])
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        activeSessionObserver = model.activeSession?.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.render() }
        render()
    }

    private func render() {
        guard let s = model.activeSession else {
            label.stringValue = "Open a folder to start  (⌘O)"
            return
        }
        var lines = ["\(s.name)", "\(s.tabs.count) tab(s)"]
        if let t = s.activeTab { lines.append("▸ \(t.title)  [\(t.kind.rawValue)]") }
        else { lines.append("No tabs open") }
        label.stringValue = lines.joined(separator: "\n")
    }
}

// MARK: - Sidebar (files + sessions)

/// Phase 0: a vertical split with a FILES placeholder on top and a working SESSIONS list below
/// (real, model-driven — proves the layout + binding). The file tree replaces the placeholder in
/// Phase 2; the sessions panel is fleshed out in Phase 5.
final class SidebarViewController: NSViewController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private let sessionsStack = NSStackView()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = false                 // horizontal divider → stacked panes
        split.dividerStyle = .thin
        split.autosaveName = "MulteeSidebarSplit"

        split.addArrangedSubview(makeFilesPane())
        split.addArrangedSubview(makeSessionsPane())
        self.view = split
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuildSessions() }
            .store(in: &cancellables)
        rebuildSessions()
    }

    // FILES placeholder (NSOutlineView arrives in Phase 2)
    private func makeFilesPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        let header = Self.header("FILES")
        let placeholder = NSTextField(labelWithString: "File tree — Phase 2")
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [header, placeholder])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
        ])
        return pane
    }

    // SESSIONS list (real, model-driven)
    private func makeSessionsPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        let header = Self.header("SESSIONS")

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 2
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = sessionsStack
        NSLayoutConstraint.activate([
            sessionsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 8),
            sessionsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -8),
            sessionsStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
        ])

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
        ])
        return pane
    }

    private func rebuildSessions() {
        sessionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if model.sessions.isEmpty {
            let empty = NSTextField(labelWithString: "No sessions open")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            sessionsStack.addArrangedSubview(empty)
            return
        }
        for session in model.sessions {
            let row = SessionRowView(
                name: session.name,
                isActive: session.id == model.activeSessionID,
                status: session.status,
                onSelect: { [weak self] in self?.model.activeSessionID = session.id },
                onClose: { [weak self] in self?.model.closeSession(session.id) }
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            sessionsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sessionsStack.widthAnchor).isActive = true
        }
    }

    static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// One row in the SESSIONS list: status dot, name (click to activate), close button.
final class SessionRowView: NSView {
    private let onSelect: () -> Void
    private let onClose: () -> Void

    init(name: String, isActive: Bool, status: ClaudeState,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive ? NSColor(white: 1, alpha: 0.08).cgColor : .clear

        let dot = StatusDot(state: status)

        let nameButton = NSButton(title: name, target: self, action: #selector(select))
        nameButton.isBordered = false
        nameButton.bezelStyle = .inline
        nameButton.alignment = .left
        nameButton.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        nameButton.font = .systemFont(ofSize: 13, weight: isActive ? .medium : .regular)
        nameButton.setButtonType(.momentaryChange)

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 11)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close session"
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, nameButton, NSView(), close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func select() { onSelect() }
    @objc private func closeTapped() { onClose() }
}

/// Small colored status dot.
final class StatusDot: NSView {
    init(state: ClaudeState) {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
        layer?.cornerRadius = 4
        let color: NSColor
        switch state {
        case .idle:    color = NSColor(white: 0.45, alpha: 1)
        case .working: color = .systemBlue
        case .needs:   color = .systemOrange
        }
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Flipped clip view so the sessions stack lays out top-down inside the scroll view.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
