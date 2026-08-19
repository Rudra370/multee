import AppKit
import Combine

/// Toggle the SESSIONS panel collapse — same static-hook pattern as `SidebarSearchHook`; the debug
/// harness drives it (the chevron is a button the sandbox can't click).
enum SidebarCollapseHook { static var toggle: (() -> Void)? }

/// Root layout: a horizontal split with the workspace (center) on the left and the sidebar (files /
/// sessions) on the right. A *plain* NSSplitView (not NSSplitViewController) so the divider drags
/// reliably — the same kind the inner sessions split uses.
final class WorkspaceViewController: NSViewController, NSSplitViewDelegate {
    static weak var current: WorkspaceViewController?   // for the debug harness (split geometry)
    private let model: AppModel
    private let centerVC: CenterViewController
    private let sidebarVC: SidebarViewController
    private var didSizeOnce = false
    private var cancellables = Set<AnyCancellable>()
    /// The Files-panel mode the current sidebar width belongs to (see `sidebarWidthKey`).
    private var appliedFilesShown: Bool
    private var desiredWidth: CGFloat = 0      // this mode's remembered width, *before* clamping to the window
    private var lastTotalWidth: CGFloat = 0    // to tell a divider drag from a window resize
    private var lastResultWidth: CGFloat = 0   // width AppKit actually gave after our last move

    init(model: AppModel) {
        self.model = model
        self.centerVC = CenterViewController(model: model)
        self.sidebarVC = SidebarViewController(model: model)
        self.appliedFilesShown = model.settings.showFilesPanel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true                 // vertical divider → side-by-side
        split.dividerStyle = .thin
        // Deliberately **no** `autosaveName`: the sidebar width is remembered per Files-panel mode (see
        // `sidebarWidthKey`), and AppKit restores an autosaved position *after* our first layout — it would
        // silently override the mode's width on every launch. We persist it ourselves instead.
        split.delegate = self
        addChild(centerVC)
        addChild(sidebarVC)
        split.addArrangedSubview(centerVC.view)
        split.addArrangedSubview(sidebarVC.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)   // center flexes
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)  // sidebar keeps its width
        self.view = split
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        WorkspaceViewController.current = self
        // `@Published` publishes in *willSet*, so this closure runs before the flag flips — the one moment
        // we can still bank the outgoing mode's width before loading (and applying) the incoming one.
        model.settings.$showFilesPanel
            .sink { [weak self] shown in
                guard let self, shown != self.appliedFilesShown else { return }
                self.storeWidth()
                self.appliedFilesShown = shown
                self.desiredWidth = self.storedWidth()
                self.enforceWidth()
            }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSizeOnce, let split = view as? NSSplitView, split.bounds.width > 100,
              split.arrangedSubviews.count > 1 else { return }
        didSizeOnce = true
        migrateLegacyWidthIfNeeded()
        desiredWidth = storedWidth()
        enforceWidth()
    }

    /// Re-assert the remembered width for the current mode, clamped to what the window can currently give.
    /// `viewDidLayout` fires only for the first sizing pass (the split lays its subviews out itself), so the
    /// window-resize path comes from `splitViewDidResizeSubviews` instead.
    private func enforceWidth() {
        guard let split = view as? NSSplitView, split.bounds.width > 100,
              split.arrangedSubviews.count > 1 else { return }
        let total = split.bounds.width
        lastTotalWidth = total
        let target = clamp(desiredWidth, total: total, divider: split.dividerThickness)
        guard abs(split.arrangedSubviews[1].frame.width - target) > 1 else { return }
        split.setPosition(total - target - split.dividerThickness, ofDividerAt: 0)
        lastResultWidth = split.arrangedSubviews[1].frame.width   // what AppKit's constraints allowed
    }

    /// The sidebar width is remembered **per mode**: files+sessions wants ~320pt, a sessions-only sidebar is
    /// comfortable at ~260, and sharing one number leaves a half-empty column after every toggle.
    private func sidebarWidthKey(_ filesShown: Bool) -> String {
        filesShown ? "sidebarWidthFiles" : "sidebarWidthSessions"
    }

    private func storedWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: sidebarWidthKey(appliedFilesShown))
        return stored > 0 ? CGFloat(stored) : (appliedFilesShown ? 320 : 260)
    }

    private func storeWidth() {
        guard desiredWidth >= 120 else { return }
        UserDefaults.standard.set(Double(desiredWidth), forKey: sidebarWidthKey(appliedFilesShown))
    }

    /// Keep both panes usable: the sidebar never below 220pt, the center never below 360pt. The ceiling
    /// subtracts the divider so it matches what `constrainMinCoordinate` will actually allow — a target
    /// AppKit has to adjust would otherwise look like a user drag by the difference.
    private func clamp(_ want: CGFloat, total: CGFloat, divider: CGFloat) -> CGFloat {
        min(max(want, 220), max(220, total - 360 - divider))
    }

    /// One-time migration: the outer split used to use AppKit's `autosaveName` ("MulteeMainSplit"). Seed the
    /// files-mode width from that stored frame so an existing layout survives the upgrade.
    private func migrateLegacyWidthIfNeeded() {
        let d = UserDefaults.standard
        let key = sidebarWidthKey(true)
        guard d.double(forKey: key) == 0,
              let frames = d.array(forKey: "NSSplitView Subview Frames MulteeMainSplit") as? [String],
              frames.count > 1 else { return }
        // Each entry is "x, y, w, h, collapsed, collapsed"; the sidebar is subview 1.
        let parts = frames[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 2, let w = Double(parts[2]), w >= 120 else { return }
        d.set(w, forKey: key)
    }

    // Keep both panes usable while dragging.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat { 360 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 220 }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== sidebarVC.view   // on window resize, grow/shrink the center, keep the sidebar
    }

    /// Remember a **dragged** sidebar width for the current mode. Two things must not be mistaken for a
    /// drag: a window resize (the available width changed — re-assert the remembered width instead), and our
    /// own `setPosition` (delivered asynchronously, so a flag around the call can't catch it — but our moves
    /// land exactly on `target`, which a drag doesn't). Either would quietly rewrite the pref.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard didSizeOnce, let split = view as? NSSplitView, split.bounds.width > 100,
              split.arrangedSubviews.count > 1 else { return }
        let total = split.bounds.width
        if abs(total - lastTotalWidth) >= 0.5 { enforceWidth(); return }
        let w = split.arrangedSubviews[1].frame.width
        // Ignore both the width we asked for and the one AppKit's constraints substituted for it.
        guard w >= 120, abs(w - clamp(desiredWidth, total: total, divider: split.dividerThickness)) > 1,
              abs(w - lastResultWidth) > 1 else { return }
        desiredWidth = w
        storeWidth()
    }

    /// Debug harness: move the divider the way a *user drag* does — straight `setPosition`, bypassing
    /// `enforceWidth` — so the drag-detection path in `splitViewDidResizeSubviews` is exercised for real
    /// (the sandbox can't synthesize mouse events).
    func debugDragSidebar(_ width: CGFloat) {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
    }

    /// Debug harness: outer-split geometry (sidebar width can't be read from a screenshot).
    func debugState() -> [String: Any] {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count > 1 else { return [:] }
        return ["sidebarW": Int(split.arrangedSubviews[1].frame.width),
                "centerW": Int(split.arrangedSubviews[0].frame.width),
                "desiredW": Int(desiredWidth)]
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
    private let sessionsStack = SessionsStackView()
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
    private var lastShownMode: SidebarMode?     // to fade the pane in only on an actual Files/Changes/Search switch

    // FILES panel on/off (Settings ▸ "Show the files panel…" / ⌘B). Off = sessions-only sidebar.
    private var filesPane: NSView?
    private var filesShown: Bool
    private var branchOnlyRepo: String?          // repo whose branch we fetched one-shot (no poller)

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
        self.filesShown = model.settings.showFilesPanel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = false                 // horizontal divider → stacked panes
        split.dividerStyle = .thin
        split.autosaveName = "MulteeSidebarSplit"

        // The FILES pane is built either way (it's just a segmented control + an empty container, no tree)
        // so toggling it back on is instant; it's only *in* the split while the panel is on.
        let files = makeFilesPane()
        filesPane = files
        if filesShown { split.addArrangedSubview(files) }
        split.addArrangedSubview(makeSessionsPane())
        sidebarSplit = split
        self.view = split
        applyFilesPanelChrome()
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
        } else if !sessionsCollapsed, sessionsH < 50, collapseDriver == nil {
            // Self-heal: the SESSIONS pane has no intrinsic height; never let it vanish. Skipped while a
            // collapse/expand glide is in flight — the pane is *meant* to be transiently small mid-animation,
            // and slamming the divider here would fight the animated setPosition.
            split.setPosition(total * 0.75, ofDividerAt: 0)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        SidebarViewController.current = self
        SidebarSearchHook.reveal = { [weak self] in self?.revealSearch() }
        SidebarCollapseHook.toggle = { [weak self] in self?.toggleSessionsCollapsed() }
        model.settings.$showFilesPanel
            .receive(on: RunLoop.main)
            .sink { [weak self] shown in self?.setFilesPanel(shown) }
            .store(in: &cancellables)
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
        guard let session = model.activeSession else { teardownSidebarVCs(); currentRepo = nil; branchOnlyRepo = nil; return }
        // Files panel off → no tree, no Changes, and crucially **no `RepoStore`**: no FSEvents watcher and
        // no git poll for this session at all. The status bar still needs the branch, which the store would
        // normally bridge, so fetch it once per repo instead.
        guard filesShown else {
            teardownSidebarVCs()
            currentRepo = nil
            fetchBranchOnce(session)
            return
        }
        branchOnlyRepo = nil
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
        if let last = lastShownMode, last != sidebarMode { Motion.fadeIn(show.view) }   // fade only on a real switch
        lastShownMode = sidebarMode
        // One shared watcher + git poll; fetch only what the visible mode needs (Search needs neither).
        store.start(tree: sidebarMode == .files, changes: sidebarMode == .changes)
        if sidebarMode == .files { lastRevealedPath = nil; revealActiveFile() }   // entering Files → reveal current file
        if sidebarMode == .search { DispatchQueue.main.async { [weak self] in self?.searchVC?.focusField() } }
    }

    /// Branch for the status bar without a poller (Files panel off). Deduped per repo — `refresh()` runs on
    /// every model change.
    private func fetchBranchOnce(_ session: Session) {
        guard branchOnlyRepo != session.url else { return }
        branchOnlyRepo = session.url
        let repo = session.url
        DispatchQueue.global().async { [weak session] in
            let branch = Git.branch(repo)
            DispatchQueue.main.async { if session?.url == repo { session?.gitBranch = branch } }
        }
    }

    /// Add / remove the FILES pane (Settings checkbox or ⌘B). Removing it also tears down the git poller;
    /// re-adding rebuilds the tree from scratch via `refresh()`.
    private func setFilesPanel(_ shown: Bool) {
        guard shown != filesShown, let split = sidebarSplit, let files = filesPane else { return }
        filesShown = shown
        collapseDriver?.invalidate(); collapseDriver = nil     // a collapse glide mid-toggle would fight us
        if shown {
            split.insertArrangedSubview(files, at: 0)
            // The autosaved divider position can't help here (the pane count changed), so restore the last
            // FILES height ourselves.
            let total = split.bounds.height
            let stored = CGFloat(UserDefaults.standard.double(forKey: "sidebarFilesHeight"))
            let target = (stored > 60 && stored < total - 60) ? stored : total * 0.75
            if total > 0 { split.setPosition(target, ofDividerAt: 0) }
            didApplyInitialCollapse = false        // re-apply the SESSIONS collapse state on the next layout
        } else {
            if split.arrangedSubviews.count > 1 {
                let h = split.arrangedSubviews[0].frame.height
                if h > 60 { UserDefaults.standard.set(Double(h), forKey: "sidebarFilesHeight") }
            }
            files.removeFromSuperview()            // `removeArrangedSubview` would leave it drawn
            sessionsScroll?.isHidden = false       // SESSIONS is the whole sidebar now
        }
        applyFilesPanelChrome()
        refresh()
    }

    /// Sessions-only sidebar: there is nothing to collapse *into*, so the chevron goes away and the list is
    /// always shown. The collapsed preference itself is kept for when the FILES panel comes back.
    private func applyFilesPanelChrome() {
        collapseChevron?.isHidden = !filesShown
        if !filesShown { sessionsScroll?.isHidden = false }
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

    /// Reveal the Search segment and focus its field (⌘⇧F / "Find in Files…"). With the FILES panel off
    /// there is no Search segment, so the shortcut opens a project-search **tab** instead of no-op'ing.
    func revealSearch() {
        guard filesShown else {
            guard let session = model.activeSession else { return }
            session.openSearch()
            // The tab's view is built on the next render pass; focus the field once it exists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { SearchTabFocus.focusActive?() }
            return
        }
        filesModeSeg.selectedSegment = SidebarMode.search.rawValue
        filesModeChanged()          // shows the search pane; showSidebarContent focuses the field
    }

    /// Debug harness: select a sidebar segment (0 Files / 1 Changes / 2 Search) as if clicked.
    func debugSelectMode(_ index: Int) {
        guard filesShown else { return }
        filesModeSeg.selectedSegment = max(0, min(2, index))
        filesModeChanged()
    }

    /// Debug harness: sidebar structure + geometry (none of it readable from a screenshot).
    func debugState() -> [String: Any] {
        var d: [String: Any] = [
            "filesPanel": filesShown,
            "panes": sidebarSplit?.arrangedSubviews.count ?? 0,
            "tree": treeVC != nil,
            "store": store != nil,
            "mode": filesModeSeg.selectedSegment,
            "sessionsCollapsed": sessionsCollapsed,
            "chevronVisible": !(collapseChevron?.isHidden ?? true),
            "sessionsListVisible": !(sessionsScroll?.isHidden ?? true),
            "header": sessionsHeaderLabel.stringValue,
        ]
        if let split = sidebarSplit {
            if split.arrangedSubviews.count > 1 { d["filesH"] = Int(split.arrangedSubviews[0].frame.height) }
            d["sessionsH"] = Int(split.arrangedSubviews.last?.frame.height ?? 0)
        }
        return d
    }

    // SESSIONS pane: header (label + settings / open-repo / collapse) over the session list.
    private func makeSessionsPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        sessionsHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sessionsHeaderLabel.textColor = .secondaryLabelColor
        sessionsHeaderLabel.lineBreakMode = .byTruncatingMiddle
        // Yield to the trailing buttons: with many projects the collapsed names label is long, and at default
        // compression resistance it pushes the +/chevron off the fixed-width header. Let it truncate instead.
        sessionsHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionsHeaderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        sessionsStack.onReorder = { [weak self] dragged, before in self?.model.moveSession(dragged, before: before) }

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
        guard filesShown else { return }   // nothing to collapse into — SESSIONS is the whole sidebar
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
            collapseDriver = Motion.drive(Motion.quick, from: current, to: target, step: { [weak split] pos in
                split?.setPosition(pos, ofDividerAt: 0)
            }, done: { [weak self] in self?.collapseDriver = nil })
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
        sessionsHeaderLabel.stringValue = (sessionsCollapsed && filesShown && !model.sessions.isEmpty)
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
                sessionID: session.id,
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
final class SessionRowView: PointerView, NSDraggingSource {
    let sessionID: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private var mouseDownAt: NSPoint = .zero
    private var didDrag = false

    init(sessionID: String, name: String, isActive: Bool, status: ClaudeState,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.sessionID = sessionID
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive ? NSColor(white: 1, alpha: 0.08).cgColor : .clear
        toolTip = "Switch to this session — drag to reorder"

        let dot = StatusDot(state: status)

        // A plain label (not a button) so the whole row handles click-to-select vs drag-to-reorder
        // (a button would swallow the drag). Mirrors the tab chip.
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        nameLabel.font = .systemFont(ofSize: 13, weight: isActive ? .medium : .regular)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = PointerButton(); close.title = "✕"; close.target = self; close.action = #selector(closeTapped)
        close.isBordered = false
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 11)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close session"
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, nameLabel, NSView(), close])
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
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Click vs drag, like the tab chip: a small move past threshold starts a reorder drag; a clean
    // mouse-up (no drag) selects. The ✕ close button is a real button, so it handles its own clicks.
    override func mouseDown(with event: NSEvent) { mouseDownAt = event.locationInWindow; didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownAt.x, dy = event.locationInWindow.y - mouseDownAt.y
        if (dx * dx + dy * dy) > 16 { didDrag = true; beginReorderDrag(event) }   // ~4pt
    }
    override func mouseUp(with event: NSEvent) { if !didDrag { onSelect() } }
    @objc private func closeTapped() { onClose() }

    private func beginReorderDrag(_ event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(sessionID, forType: .multeeSession)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    // Show the "grabbing" (closed-hand) cursor while a row is being dragged; restore on drop.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { NSCursor.closedHand.push() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { NSCursor.pop() }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

/// The SESSIONS list as a drop target: rows (`SessionRowView`) are the drag sources, this stack is the
/// destination — it shows a horizontal insertion line and, on drop, reorders via `onReorder`. Mirrors the
/// tab bar's reorder, vertical instead of horizontal.
final class SessionsStackView: NSStackView {
    var onReorder: ((_ dragged: String, _ beforeID: String?) -> Void)?
    private let dropIndicator = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        addSubview(dropIndicator)   // non-arranged → stays where we frame it
        registerForDraggedTypes([.multeeSession])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { showDrop(s); return .move }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { showDrop(s); return .move }
    override func draggingExited(_ s: NSDraggingInfo?) { dropIndicator.isHidden = true }
    override func draggingEnded(_ s: NSDraggingInfo) { dropIndicator.isHidden = true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard let dragged = s.draggingPasteboard.string(forType: .multeeSession) else { return false }
        let (beforeID, _) = insertionPoint(at: s.draggingLocation)
        if beforeID != dragged { onReorder?(dragged, beforeID) }
        return true
    }

    private func showDrop(_ s: NSDraggingInfo) {
        let (_, y) = insertionPoint(at: s.draggingLocation)
        dropIndicator.frame = NSRect(x: 2, y: y - 1, width: max(0, bounds.width - 4), height: 2)
        dropIndicator.isHidden = false
    }

    /// (session to insert *before* — nil = end, indicator Y). Rows are laid out top→bottom in array order;
    /// "before a row" = visually above its centre. Direction depends on `isFlipped`.
    private func insertionPoint(at windowPoint: NSPoint) -> (String?, CGFloat) {
        let p = convert(windowPoint, from: nil)
        let rows = arrangedSubviews.compactMap { $0 as? SessionRowView }
        for row in rows {
            let f = row.frame
            let insertBefore = isFlipped ? (p.y < f.midY) : (p.y > f.midY)
            if insertBefore { return (row.sessionID, isFlipped ? f.minY : f.maxY) }
        }
        let endY = rows.last.map { isFlipped ? $0.frame.maxY : $0.frame.minY } ?? bounds.midY
        return (nil, endY)
    }
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
