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

// MARK: - Sidebar (files + sessions)

/// Phase 0: a vertical split with a FILES placeholder on top and a working SESSIONS list below
/// (real, model-driven — proves the layout + binding). The file tree replaces the placeholder in
/// Phase 2; the sessions panel is fleshed out in Phase 5.
final class SidebarViewController: NSViewController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private let sessionsStack = NSStackView()
    private let filesContainer = NSView()
    private var treeVC: FileTreeViewController?
    private var changesVC: ChangesViewController?
    private var currentRepo: String?
    private let filesModeSeg = NSSegmentedControl(labels: ["Files", "Changes"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private var changesMode: Bool { filesModeSeg.selectedSegment == 1 }

    // SESSIONS header + collapse
    private let sessionsHeaderLabel = NSTextField(labelWithString: "SESSIONS")
    private var sessionsScroll: NSScrollView?
    private var collapseChevron: ClosureButton?
    private weak var sidebarSplit: NSSplitView?
    private var sessionsCollapsed = UserDefaults.standard.bool(forKey: "sessionsCollapsed")
    private var expandedDividerPos: CGFloat = 0
    private var didApplyInitialCollapse = false

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
        sidebarSplit = split
        self.view = split
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Apply the persisted collapsed state once we have a real height to compute against.
        if !didApplyInitialCollapse, (sidebarSplit?.bounds.height ?? 0) > 0 {
            didApplyInitialCollapse = true
            if sessionsCollapsed { applyCollapse(animated: false) }
        }
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
        rebuildSessions()
        syncFileTree()
    }

    // FILES pane — a Files/Changes toggle over a container that holds the tree or the changes view.
    private func makeFilesPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.145, alpha: 1).cgColor

        filesModeSeg.selectedSegment = max(0, min(1, UserDefaults.standard.integer(forKey: "rightMode")))
        filesModeSeg.target = self
        filesModeSeg.action = #selector(filesModeChanged)
        filesModeSeg.controlSize = .small
        filesModeSeg.segmentStyle = .rounded
        filesModeSeg.translatesAutoresizingMaskIntoConstraints = false
        filesContainer.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(filesModeSeg)
        pane.addSubview(filesContainer)
        NSLayoutConstraint.activate([
            filesModeSeg.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            filesModeSeg.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            filesContainer.topAnchor.constraint(equalTo: filesModeSeg.bottomAnchor, constant: 6),
            filesContainer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            filesContainer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            filesContainer.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    @objc private func filesModeChanged() {
        UserDefaults.standard.set(filesModeSeg.selectedSegment, forKey: "rightMode")
        showSidebarContent()
    }

    /// Rebuild the tree + changes VCs when the active session changes, then show the one for the mode.
    private func syncFileTree() {
        guard let session = model.activeSession else { teardownSidebarVCs(); currentRepo = nil; return }
        if currentRepo != session.url {
            teardownSidebarVCs()
            currentRepo = session.url
            let tree = FileTreeViewController(repo: session.url, settings: model.settings,
                onOpen: { [weak self] path in self?.model.activeSession?.openFile(path) })
            let changes = ChangesViewController(repo: session.url,
                onOpenDiff: { [weak self] path in self?.model.activeSession?.openDiff(path) },
                onOpenFile: { [weak self] path in self?.model.activeSession?.openFile(path) })
            addChild(tree); addChild(changes)
            treeVC = tree; changesVC = changes
        }
        showSidebarContent()
    }

    private func showSidebarContent() {
        guard let treeVC, let changesVC else { return }
        let show: NSViewController = changesMode ? changesVC : treeVC
        let hide: NSViewController = changesMode ? treeVC : changesVC
        hide.view.removeFromSuperview()
        if show.view.superview == nil {
            show.view.translatesAutoresizingMaskIntoConstraints = false
            filesContainer.addSubview(show.view)
            NSLayoutConstraint.activate([
                show.view.topAnchor.constraint(equalTo: filesContainer.topAnchor),
                show.view.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),
                show.view.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
                show.view.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
            ])
        }
    }

    private func teardownSidebarVCs() {
        treeVC?.stop(); treeVC?.view.removeFromSuperview(); treeVC?.removeFromParent(); treeVC = nil
        changesVC?.stop(); changesVC?.view.removeFromSuperview(); changesVC?.removeFromParent(); changesVC = nil
    }

    // SESSIONS pane: header (label + settings / open-repo / collapse) over the session list.
    private func makeSessionsPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        sessionsHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sessionsHeaderLabel.textColor = .secondaryLabelColor
        sessionsHeaderLabel.lineBreakMode = .byTruncatingMiddle

        let gear = ClosureButton(symbol: "gearshape") { [weak self] in self?.model.showSettings = true }
        gear.toolTip = "Settings"
        let add = ClosureButton(symbol: "plus") { [weak self] in self?.openRepo() }
        add.toolTip = "Open a repo"
        let chevron = ClosureButton(symbol: sessionsCollapsed ? "chevron.up" : "chevron.down") { [weak self] in
            self?.toggleSessionsCollapsed()
        }
        chevron.toolTip = "Collapse / expand"
        collapseChevron = chevron

        let header = NSStackView(views: [sessionsHeaderLabel, NSView(), gear, add, chevron])
        header.orientation = .horizontal
        header.spacing = 6

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
        sessionsScroll = scroll
        NSLayoutConstraint.activate([
            sessionsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 8),
            sessionsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -8),
            sessionsStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
        ])

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        return pane
    }

    /// Toggle the collapsed SESSIONS panel: shrink to just its header (showing session names) and back.
    private func toggleSessionsCollapsed() {
        sessionsCollapsed.toggle()
        UserDefaults.standard.set(sessionsCollapsed, forKey: "sessionsCollapsed")
        collapseChevron?.image = NSImage(systemSymbolName: sessionsCollapsed ? "chevron.up" : "chevron.down",
                                         accessibilityDescription: nil)
        applyCollapse(animated: true)
        rebuildSessions()
    }

    private func applyCollapse(animated: Bool) {
        guard let split = sidebarSplit else { return }
        sessionsScroll?.isHidden = sessionsCollapsed
        let total = split.bounds.height
        guard total > 0 else { return }
        let headerH: CGFloat = 38
        if sessionsCollapsed {
            expandedDividerPos = split.subviews.first?.frame.height ?? total * 0.62
            split.setPosition(total - headerH, ofDividerAt: 0)
        } else {
            let pos = expandedDividerPos > 0 ? expandedDividerPos : total * 0.62
            split.setPosition(pos, ofDividerAt: 0)
        }
    }

    private func openRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { model.openRepo(url.path) }
    }

    private func rebuildSessions() {
        // Collapsed header shows the open session names instead of "SESSIONS".
        sessionsHeaderLabel.stringValue = (sessionsCollapsed && !model.sessions.isEmpty)
            ? model.sessions.map(\.name).joined(separator: ", ") : "SESSIONS"

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
