import AppKit
import Combine

/// Root layout: a horizontal split with the workspace (center) on the left and the sidebar (files /
/// sessions) on the right. A *plain* NSSplitView (not NSSplitViewController) so the divider drags
/// reliably — the same kind the inner sessions split uses.
final class WorkspaceViewController: NSViewController, NSSplitViewDelegate {
    private let model: AppModel
    private let centerVC: CenterViewController
    private let sidebarVC: SidebarViewController
    private var didSizeOnce = false

    init(model: AppModel) {
        self.model = model
        self.centerVC = CenterViewController(model: model)
        self.sidebarVC = SidebarViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true                 // vertical divider → side-by-side
        split.dividerStyle = .thin
        split.autosaveName = "MulteeMainSplit"
        split.delegate = self
        addChild(centerVC)
        addChild(sidebarVC)
        split.addArrangedSubview(centerVC.view)
        split.addArrangedSubview(sidebarVC.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)   // center flexes
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)  // sidebar keeps its width
        self.view = split
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let split = view as? NSSplitView, split.bounds.width > 100,
              split.arrangedSubviews.count > 1 else { return }
        let total = split.bounds.width
        let sidebarW = split.arrangedSubviews[1].frame.width
        // First layout: set the default sidebar width if nothing valid was restored.
        if !didSizeOnce {
            didSizeOnce = true
            if sidebarW < 120 || sidebarW > total - 200 {
                split.setPosition(total - 320, ofDividerAt: 0)
            }
        } else if sidebarW < 120 {
            // Self-heal: the inner split has no intrinsic width, so never let it collapse to nothing.
            split.setPosition(total - 320, ofDividerAt: 0)
        }
    }

    // Keep both panes usable while dragging.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat { 360 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 220 }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== sidebarVC.view   // on window resize, grow/shrink the center, keep the sidebar
    }
}

// MARK: - Sidebar (files + sessions)

/// Phase 0: a vertical split with a FILES placeholder on top and a working SESSIONS list below
/// (real, model-driven — proves the layout + binding). The file tree replaces the placeholder in
/// Phase 2; the sessions panel is fleshed out in Phase 5.
final class SidebarViewController: NSViewController {
    static weak var current: SidebarViewController?   // for the debug harness (segment switching)
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var sessionStatusObservers: [String: AnyCancellable] = [:]   // per-session dot refresh
    private let sessionsStack = NSStackView()
    private let filesContainer = NSView()
    private var treeVC: FileTreeViewController?
    private var changesVC: ChangesViewController?
    private var searchVC: SearchViewController?
    private var store: RepoStore?            // one shared git poller for the tree + Changes
    private var branchBridge: AnyCancellable?   // store.branch → session.gitBranch
    private var currentRepo: String?
    private var lastRevealedPath: String?    // dedup auto-reveal of the active file in the tree
    private let filesModeSeg: PointerSegmentedControl = {
        let s = PointerSegmentedControl()
        s.segmentCount = 3
        func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        s.setImage(icon("doc.on.doc"), forSegment: 0)
        s.setImage(icon("arrow.triangle.branch"), forSegment: 1)
        s.setImage(icon("magnifyingglass"), forSegment: 2)
        s.setToolTip("Files", forSegment: 0)
        s.setToolTip("Changes (git)", forSegment: 1)
        s.setToolTip("Search", forSegment: 2)
        s.trackingMode = .selectOne
        return s
    }()
    private enum SidebarMode: Int { case files = 0, changes = 1, search = 2 }
    private var sidebarMode: SidebarMode { SidebarMode(rawValue: filesModeSeg.selectedSegment) ?? .files }
    private var changesMode: Bool { sidebarMode == .changes }
    private var fileActionsBar: NSStackView?   // new file / new folder / collapse-all (Files mode only)

    // SESSIONS header + collapse
    private let sessionsHeaderLabel = NSTextField(labelWithString: "SESSIONS")
    private var sessionsScroll: NSScrollView?
    private var collapseChevron: ClosureButton?
    private weak var sidebarSplit: NSSplitView?
    private var sessionsCollapsed = UserDefaults.standard.bool(forKey: "sessionsCollapsed")
    private var expandedDividerPos: CGFloat = 0
    private var didApplyInitialCollapse = false
    private var collapseDriver: Timer?   // in-flight collapse/expand glide (cancelled on re-toggle)

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
        guard let split = sidebarSplit, split.bounds.height > 100, split.arrangedSubviews.count > 1 else { return }
        let total = split.bounds.height
        let sessionsH = split.arrangedSubviews[1].frame.height

        if !didApplyInitialCollapse {
            didApplyInitialCollapse = true
            if sessionsCollapsed {
                applyCollapse(animated: false)
            } else if sessionsH < 70 || sessionsH > total - 100 {
                // Default SESSIONS to the bottom 25% when nothing valid was restored.
                split.setPosition(total * 0.75, ofDividerAt: 0)
            }
        } else if !sessionsCollapsed, sessionsH < 50 {
            // Self-heal: the SESSIONS pane has no intrinsic height; never let it vanish.
            split.setPosition(total * 0.75, ofDividerAt: 0)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        SidebarViewController.current = self
        SidebarSearchHook.reveal = { [weak self] in self?.revealSearch() }
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        // Pause git polling while the app is in the background (Claude status still arrives via hooks).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }

    @objc private func appResignedActive() { store?.stop() }
    @objc private func appBecameActive() { if model.activeSession != nil { showSidebarContent() } }

    private func refresh() {
        rebuildSessions()
        syncFileTree()
        observeSessionStatus()
        revealActiveFile()
    }

    /// Auto-reveal the active file in the tree (VS Code-style): when the active tab is a file, expand to
    /// it, select it, scroll it in. Files mode only; deduped so we don't fight manual scrolling.
    private func revealActiveFile() {
        guard sidebarMode == .files, let treeVC,
              let session = model.activeSession, let tab = session.activeTab,
              tab.kind == .file, let abs = tab.path else { return }
        let prefix = session.url.hasSuffix("/") ? session.url : session.url + "/"
        let rel = abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : abs
        guard rel != lastRevealedPath else { return }
        lastRevealedPath = rel
        treeVC.reveal(rel)
    }

    /// Refresh the SESSIONS dots when *any* session's status changes. The hook routing mutates a
    /// session's `tabStatus`, which fires that Session's `objectWillChange` — but this view only
    /// observes `model.objectWillChange`, so without this the dots were stale until the model
    /// republished (e.g. on a session switch). Re-established whenever the session set changes;
    /// rebuilds only the (cheap) sessions list, never the file-tree/git poll.
    private func observeSessionStatus() {
        sessionStatusObservers = Dictionary(uniqueKeysWithValues: model.sessions.map { session in
            (session.id, session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.rebuildSessions(); self?.revealActiveFile() })
        })
    }

    // FILES pane — a Files/Changes toggle over a container that holds the tree or the changes view.
    private func makeFilesPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.145, alpha: 1).cgColor

        filesModeSeg.selectedSegment = max(0, min(2, UserDefaults.standard.integer(forKey: "rightMode")))
        filesModeSeg.target = self
        filesModeSeg.action = #selector(filesModeChanged)
        filesModeSeg.controlSize = .small
        filesModeSeg.segmentStyle = .rounded
        filesModeSeg.toolTip = "Files tree / Changes (git)"
        filesModeSeg.translatesAutoresizingMaskIntoConstraints = false
        filesContainer.translatesAutoresizingMaskIntoConstraints = false

        // Tree toolbar: new file / new folder / collapse-all (VS Code's Explorer actions). Files mode only.
        let iconSize: CGFloat = 13
        let newFile = ClosureButton(symbol: "doc.badge.plus", pointSize: iconSize) { [weak self] in self?.treeVC?.beginNewFile() }
        newFile.toolTip = "New file"
        let newFolder = ClosureButton(symbol: "folder.badge.plus", pointSize: iconSize) { [weak self] in self?.treeVC?.beginNewFolder() }
        newFolder.toolTip = "New folder"
        let collapse = ClosureButton(symbol: "arrow.down.right.and.arrow.up.left", pointSize: iconSize) { [weak self] in self?.treeVC?.collapseAll() }
        collapse.toolTip = "Collapse all folders"
        let actions = NSStackView(views: [newFile, newFolder, collapse])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.isHidden = sidebarMode != .files
        fileActionsBar = actions

        pane.addSubview(filesModeSeg)
        pane.addSubview(actions)
        pane.addSubview(filesContainer)
        NSLayoutConstraint.activate([
            filesModeSeg.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            filesModeSeg.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            actions.centerYAnchor.constraint(equalTo: filesModeSeg.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: filesModeSeg.trailingAnchor, constant: 8),
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
            lastRevealedPath = nil          // new tree → reveal the active file afresh
            let store = RepoStore(repo: session.url, settings: model.settings)
            let tree = FileTreeViewController(store: store, settings: model.settings,
                onOpen: { [weak self] path in self?.model.activeSession?.openFile(path) },
                onRename: { [weak self] old, new in self?.model.activeSession?.fileRenamed(from: old, to: new) },
                onDelete: { [weak self] rel in self?.model.activeSession?.fileDeleted(rel) })
            let changes = ChangesViewController(store: store,
                onOpenDiff: { [weak self] path in self?.model.activeSession?.openDiff(path) },
                onOpenFile: { [weak self] path in self?.model.activeSession?.openFile(path) })
            let search = SearchViewController(repo: session.url,
                onOpen: { [weak self] rel, line in self?.openSearchResult(rel, line) })
            search.onOpenAsTab = { [weak self] query, options in
                SearchSeed.pending = (query, options)        // CenterViewController.render seeds the new tab
                let title = query.isEmpty ? "Search" : "Search: \(query)"
                self?.model.activeSession?.addTab(Tab(kind: .search, title: title))   // always a fresh tab (multiple allowed)
            }
            addChild(tree); addChild(changes); addChild(search)
            treeVC = tree; changesVC = changes; searchVC = search; self.store = store
            // Bridge the git poller's branch onto the session so the status bar can show it (no 2nd poller).
            branchBridge = store.$branch.sink { [weak session] in session?.gitBranch = $0 }
        }
        showSidebarContent()
    }

    private func showSidebarContent() {
        fileActionsBar?.isHidden = sidebarMode != .files   // tree actions only apply to the Files tree
        guard let treeVC, let changesVC, let searchVC, let store else { return }
        let panes: [(SidebarMode, NSViewController)] = [(.files, treeVC), (.changes, changesVC), (.search, searchVC)]
        for (mode, vc) in panes where mode != sidebarMode && vc.isViewLoaded { vc.view.removeFromSuperview() }
        let show = panes.first { $0.0 == sidebarMode }!.1
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
        // One shared watcher + git poll; fetch only what the visible mode needs (Search needs neither).
        store.start(tree: sidebarMode == .files, changes: sidebarMode == .changes)
        if sidebarMode == .files { lastRevealedPath = nil; revealActiveFile() }   // entering Files → reveal current file
        if sidebarMode == .search { DispatchQueue.main.async { [weak self] in self?.searchVC?.focusField() } }
    }

    private func teardownSidebarVCs() {
        store?.stop(); store = nil
        treeVC?.view.removeFromSuperview(); treeVC?.removeFromParent(); treeVC = nil
        changesVC?.view.removeFromSuperview(); changesVC?.removeFromParent(); changesVC = nil
        // Search may never have been shown — only touch its view if it was actually loaded.
        if let sv = searchVC { if sv.isViewLoaded { sv.view.removeFromSuperview() }; sv.removeFromParent() }
        searchVC = nil
    }

    /// A search hit was clicked → open that file in the active session and jump to its line.
    private func openSearchResult(_ rel: String, _ line: Int) {
        FileNavigator.openAt?(rel, line)
    }

    /// Reveal the Search segment and focus its field (⌘⇧F / "Find in Files…").
    func revealSearch() {
        filesModeSeg.selectedSegment = SidebarMode.search.rawValue
        filesModeChanged()          // shows the search pane; showSidebarContent focuses the field
    }

    /// Debug harness: select a sidebar segment (0 Files / 1 Changes / 2 Search) as if clicked.
    func debugSelectMode(_ index: Int) {
        filesModeSeg.selectedSegment = max(0, min(2, index))
        filesModeChanged()
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
        let newProj = ClosureButton(symbol: "folder.badge.plus") { [weak self] in
            guard let self else { return }
            NewProject.present(model: self.model)
        }
        newProj.toolTip = "New project…"
        let add = ClosureButton(symbol: "plus") { [weak self] in self?.openRepo() }
        add.toolTip = "Open an existing folder"
        let chevron = ClosureButton(symbol: sessionsCollapsed ? "chevron.up" : "chevron.down") { [weak self] in
            self?.toggleSessionsCollapsed()
        }
        chevron.toolTip = "Collapse / expand"
        collapseChevron = chevron

        let header = NSStackView(views: [sessionsHeaderLabel, NSView(), gear, newProj, add, chevron])
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
        let target: CGFloat
        if sessionsCollapsed {
            expandedDividerPos = split.subviews.first?.frame.height ?? total * 0.62
            target = total - headerH
        } else {
            target = expandedDividerPos > 0 ? expandedDividerPos : total * 0.62
        }
        collapseDriver?.invalidate()
        // Safe to drive the divider per frame here: both panes are plain AppKit (file tree + sessions
        // list), no terminal to reflow (cf. the bottom dock, which can't — D28).
        let current = split.subviews.first?.frame.height ?? target
        if animated {
            collapseDriver = Motion.drive(Motion.quick, from: current, to: target) { [weak split] pos in
                split?.setPosition(pos, ofDividerAt: 0)
            }
        } else {
            split.setPosition(target, ofDividerAt: 0)
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
                onClose: { [weak self] in
                    guard let self else { return }
                    if UnsavedGuard.confirmCloseMany(session.tabs.filter { $0.dirty }, verb: "closing this folder") {
                        self.model.closeSession(session.id)
                    }
                }
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
final class SessionRowView: PointerView {
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

        let nameButton = PointerButton()
        nameButton.title = name
        nameButton.target = self
        nameButton.action = #selector(select)
        nameButton.isBordered = false
        nameButton.bezelStyle = .inline
        nameButton.alignment = .left
        nameButton.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        nameButton.font = .systemFont(ofSize: 13, weight: isActive ? .medium : .regular)
        nameButton.setButtonType(.momentaryChange)
        nameButton.toolTip = "Switch to this session"

        let close = PointerButton(); close.title = "✕"; close.target = self; close.action = #selector(closeTapped)
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
        case .idle:           color = NSColor(white: 0.45, alpha: 1)
        case .working:        color = .systemBlue
        case .needs, .done:   color = .systemOrange   // both are "needs your attention"
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
