import AppKit
import Combine

/// Lets `Session` ask the (view-owning) CenterViewController to rebuild a tab's terminal fresh — used by
/// Restart / convert-to-terminal, since a dead SwiftTerm view can't be restarted in place.
enum TerminalLifecycle {
    static var rebuild: ((String) -> Void)?   // tabID → kill the old PTY/view and respawn it
}

/// The workspace pane: a tab bar on top and the active tab's content below. Tab content views stay
/// mounted (hidden) so terminals keep running across switches; content is lazily created the first
/// time a tab becomes active (so a restored session only spawns its active tab).
final class CenterViewController: NSViewController, NSSplitViewDelegate {
    static weak var current: CenterViewController?   // for the quick-terminal bottom dock

    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var activeSessionObserver: AnyCancellable?

    private let tabBar = TabBarView()
    private let contentArea = NSView()
    /// Vertical split hosting the content area, with the quick terminal docked below it in "bottom" mode.
    private let centerSplit = NSSplitView()
    private var bottomDock: NSView?
    private let endedOverlay = SessionEndedOverlay()          // centered card shown over a terminal that exited
    private let emptyLabel = NSTextField(labelWithString: "Open a folder to start  (⌘O)")
    private let openButton = PointerButton()
    private var emptyStack: NSView?
    private var contentViews: [String: NSView] = [:]
    private var contentVCs: [String: NSViewController] = [:]   // VC-backed content (editor, diff)
    private var contentPaths: [String: String] = [:]          // path each content view was built for (rename detect)
    private var lastActiveTabID: String?                       // focus a tab's editor only when it newly becomes active
    private var pendingReveal: [String: Int] = [:]            // tabID → line to jump to once its editor is built (search hit)

    private let statusBar: StatusBarView

    init(model: AppModel) {
        self.model = model
        self.statusBar = StatusBarView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Layer-backed backdrop. This makes the embedded SwiftTerm view implicitly layer-backed,
        // so it renders blank in the self-screenshot (we verify terminal content via the buffer-text
        // dump instead) — but the chips/editor/diff (standard AppKit) DO capture, which a non-layer
        // BackgroundView broke. Real users see the terminal fine (layer-backed is normal for it).
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        // The content area lives inside a vertical split so the quick terminal can dock beneath it
        // (bottom mode) with a draggable divider; with no dock it's the split's only pane and fills.
        centerSplit.isVertical = false                  // horizontal divider → stacked
        centerSplit.dividerStyle = .thin
        centerSplit.delegate = self
        centerSplit.translatesAutoresizingMaskIntoConstraints = false
        centerSplit.setContentHuggingPriority(.defaultLow, for: .vertical)
        centerSplit.addArrangedSubview(contentArea)

        // Vertical stack guarantees tabBar (fixed height) sits ABOVE a filling content split with no
        // overlap — manual top/bottom constraints were collapsing the bar to zero height. The status bar
        // sits at the bottom of the *center* pane only (so it doesn't span the sidebar).
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let vstack = NSStackView(views: [tabBar, centerSplit, statusBar])
        vstack.orientation = .vertical
        vstack.spacing = 0
        vstack.distribution = .fill
        vstack.alignment = .leading
        vstack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vstack)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        openButton.title = "Open Folder…"
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openFolderTapped)
        openButton.toolTip = "Open a folder (⌘O)"
        let emptyStack = NSStackView(views: [emptyLabel, openButton])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 12
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(emptyStack)
        self.emptyStack = emptyStack

        // The "Session ended" overlay fills the content area (a dimming scrim with a centered card), hidden
        // until a terminal exits. Brought to the front (above the active terminal) when shown.
        endedOverlay.translatesAutoresizingMaskIntoConstraints = false
        endedOverlay.isHidden = true
        contentArea.addSubview(endedOverlay)
        NSLayoutConstraint.activate([
            endedOverlay.topAnchor.constraint(equalTo: contentArea.topAnchor),
            endedOverlay.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            endedOverlay.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            endedOverlay.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: root.topAnchor),
            vstack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vstack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            tabBar.heightAnchor.constraint(equalToConstant: 34),
            tabBar.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            centerSplit.widthAnchor.constraint(equalTo: vstack.widthAnchor),  // contentArea fills the split
            statusBar.widthAnchor.constraint(equalTo: vstack.widthAnchor),   // height = StatusBarView intrinsic (font-driven)

            emptyStack.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
        ])
        self.view = root

        tabBar.onSelect      = { [weak self] id in self?.model.activeSession?.activate(id) }
        tabBar.onClose       = { [weak self] id in
            guard let session = self?.model.activeSession, let tab = session.tabs.first(where: { $0.id == id }) else { return }
            if UnsavedGuard.confirmClose(tab) { session.closeTab(id) }
        }
        tabBar.onNewClaude   = { [weak self] args in
            guard let self else { return }
            // Empty args (the ✦ button and the "Default" menu item) → use the Settings default args,
            // matching the auto-launched Claude when a repo is first opened.
            let resolved = args.isEmpty ? self.model.settings.defaultArgs : args
            self.model.activeSession?.addTab(Tab(kind: .claude, title: "Claude", args: resolved))
        }
        tabBar.onNewTerminal = { [weak self] in
            self?.model.activeSession?.addTab(Tab(kind: .terminal, title: "Terminal"))
        }
        tabBar.onReorder     = { [weak self] dragged, beforeID in
            guard let session = self?.model.activeSession else { return }
            if let beforeID { session.moveTab(dragged, before: beforeID) } else { session.moveTabToEnd(dragged) }
        }
    }

    @objc private func openFolderTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { model.openRepo(url.path) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CenterViewController.current = self
        TerminalLifecycle.rebuild = { [weak self] tabID in self?.rebuildTerminal(tabID) }
        // Let the unsaved-changes guard save any (already-mounted) editor tab by id, without it needing
        // to know about view controllers. A dirty tab has always been viewed, so its editor exists here.
        UnsavedGuard.saveTab = { [weak self] id in (self?.contentVCs[id] as? SourceEditing)?.sourceEditor?.saveImmediately() }
        // "Install formatter" → open a Terminal tab that runs the command (then drops to an interactive shell).
        FormatterInstall.run = { [weak self] command in
            self?.model.activeSession?.addTab(Tab(kind: .terminal, title: "Install", args: command))
        }
        // A project-search hit (sidebar / search tab) → open the file in the active session and jump to the line.
        FileNavigator.openAt = { [weak self] rel, line in
            guard let self, let session = self.model.activeSession else { return }
            let before = session.activeTabID
            session.openFile(rel)
            let id = session.activeTabID
            if id == before, let editor = (self.contentVCs[id] as? SourceEditing)?.sourceEditor {
                editor.goToLine(line)            // already the active editor → jump now (no render to ride)
            } else {
                self.pendingReveal[id] = line    // otherwise consumed in render() once its editor is built & active
            }
        }
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
        pruneOrphanContent()

        // No session at all → the open-a-folder empty state (no tab bar).
        guard let session = model.activeSession else {
            tabBar.isHidden = true
            emptyStack?.isHidden = false
            emptyLabel.stringValue = "Open a folder to start  (⌘O)"
            openButton.isHidden = false
            contentViews.values.forEach { $0.isHidden = true }
            endedOverlay.isHidden = true
            return
        }

        // A session is open → the tab bar stays visible (so you can always start a new tab), even
        // when every tab is closed.
        tabBar.isHidden = false
        tabBar.render(session: session, activeTabID: session.activeTabID)

        guard let tab = session.activeTab else {
            emptyStack?.isHidden = false
            emptyLabel.stringValue = "No tabs open"
            openButton.isHidden = true
            contentViews.values.forEach { $0.isHidden = true }
            endedOverlay.isHidden = true
            return
        }

        emptyStack?.isHidden = true

        // Lazily create the active tab's content view.
        if contentViews[tab.id] == nil {
            let v = makeContentView(for: tab, session: session)
            mount(v)
            contentViews[tab.id] = v
            contentPaths[tab.id] = tab.path ?? ""
            session.markShown(tab.id)
        } else if (tab.kind == .file || tab.kind == .diff), contentPaths[tab.id] != (tab.path ?? "") {
            // The file was renamed/moved while open — retarget the editor (keeps edits) or rebuild a
            // read-only viewer against the new path.
            retargetContent(for: tab, session: session)
        }
        for (id, v) in contentViews { v.isHidden = (id != tab.id) }

        let outgoingEditor = ActiveEditor.current
        ActiveEditor.current = (contentVCs[tab.id] as? SourceEditing)?.sourceEditor

        // On *becoming* active (not every render — else we'd steal focus from the find bar etc.):
        // focus a text editor so you can type / search / jump immediately, or focus the terminal.
        if tab.id != lastActiveTabID {
            lastActiveTabID = tab.id
            session.clearAttention(tab.id)   // viewing a flagged tab clears its needs/done attention
            if outgoingEditor !== ActiveEditor.current { outgoingEditor?.hideFindIfShown() }   // close its floating find bar
            if let editor = contentVCs[tab.id] as? EditorViewController {
                DispatchQueue.main.async { editor.focusText() }
            }
            if let search = contentVCs[tab.id] as? SearchViewController {
                DispatchQueue.main.async { search.focusField() }
            }
        }

        // A search hit opened this file → jump to its line now the editor exists & is active (after any
        // focus above, so the centering scroll wins).
        if let line = pendingReveal[tab.id] {
            pendingReveal.removeValue(forKey: tab.id)
            // A hit in a markdown/SVG file lives in the Source, not the rendered Preview — show Source so the
            // selected line is actually visible.
            (contentVCs[tab.id] as? MarkdownViewController)?.setSourceVisible(true)
            (contentVCs[tab.id] as? ImageViewController)?.setSourceVisible(true)
            let editor = ActiveEditor.current
            DispatchQueue.main.async { editor?.goToLine(line) }
        }

        // The sidebar's "Open as Tab" seeded a query → apply it to the now-active search tab.
        if tab.kind == .search, let seed = SearchSeed.pending,
           let svc = contentVCs[tab.id] as? SearchViewController {
            SearchSeed.pending = nil
            DispatchQueue.main.async { svc.seed(seed.query, seed.options) }
        }

        if (tab.kind == .claude || tab.kind == .terminal), !tab.exited {
            DispatchQueue.main.async { TerminalStore.shared.focus(tab.id) }
        }

        updateEndedOverlay(for: tab, session: session)
    }

    /// Show the centered "Session ended" overlay over a terminal/Claude tab whose process has exited.
    private func updateEndedOverlay(for tab: Tab, session: Session) {
        let show = (tab.kind == .claude || tab.kind == .terminal) && tab.exited
        endedOverlay.isHidden = !show
        guard show else { return }
        endedOverlay.configure(
            isClaude: tab.kind == .claude,
            onRestart: { [weak session] in session?.restartTab(tab.id) },
            onOpenTerminal: { [weak session] in session?.convertToTerminal(tab.id) },
            onClose: { [weak session] in session?.closeTab(tab.id) })
        contentArea.addSubview(endedOverlay)   // keep it above the (later-mounted) terminal view
    }

    /// Kill a tab's dead terminal view and drop its cache so `render()` respawns it fresh (Restart /
    /// convert-to-terminal). A dead SwiftTerm view can't be restarted in place — `startProcess` on it
    /// spawns a process that immediately dies — so we rebuild from scratch.
    private func rebuildTerminal(_ tabID: String) {
        TerminalStore.shared.close(tabID)            // terminate the old PTY + remove the old view
        contentViews[tabID]?.removeFromSuperview()
        contentViews[tabID] = nil
        contentVCs[tabID] = nil
        contentPaths[tabID] = nil
        render()                                     // contentViews[id] == nil → spawns a fresh terminal
    }

    private func makeContentView(for tab: Tab, session: Session) -> NSView {
        switch tab.kind {
        case .claude, .terminal:
            return TerminalStore.shared.view(for: tab, cwd: session.url)
        case .file:
            // A .file tab picks its viewer by extension: images render, markdown previews, the rest edit.
            // Markdown and SVG embed the editor too (a Preview/Image ↔ Source toggle), so all three route
            // dirty state the same way.
            let onDirty: (Bool) -> Void = { [weak session] dirty in session?.setDirty(tab.id, dirty) }
            if ImageViewController.handles(tab.path) {
                let vc = ImageViewController(path: tab.path ?? "", settings: model.settings, onDirty: onDirty)
                addChild(vc)
                contentVCs[tab.id] = vc
                return vc.view
            }
            if MarkdownViewController.handles(tab.path) {
                let vc = MarkdownViewController(path: tab.path ?? "", settings: model.settings, onDirty: onDirty)
                addChild(vc)
                contentVCs[tab.id] = vc
                return vc.view
            }
            let vc = EditorViewController(path: tab.path ?? "", settings: model.settings, onDirty: onDirty)
            addChild(vc)
            contentVCs[tab.id] = vc
            return vc.view
        case .diff:
            let vc = DiffViewController(repo: session.url, path: tab.path ?? "",
                                       onOpenFile: { [weak session] in session?.openFile(tab.path ?? "") })
            addChild(vc)
            contentVCs[tab.id] = vc
            return vc.view
        case .search:
            // A full-width project search in the center. `isPrimary: false` so it doesn't steal the
            // sidebar instance's `SearchViewController.current` (the harness target).
            let vc = SearchViewController(repo: session.url, isPrimary: false,
                                          onOpen: { rel, line in FileNavigator.openAt?(rel, line) })
            addChild(vc)
            contentVCs[tab.id] = vc
            return vc.view
        }
    }

    /// A renamed-while-open file: anything hosting an editable source editor (the plain-text editor, plus
    /// markdown/SVG behind their toggle) retargets in place so unsaved edits survive; a raster image
    /// viewer or diff is rebuilt against the new path (also re-routes the viewer if the extension changed).
    private func retargetContent(for tab: Tab, session: Session) {
        if let host = contentVCs[tab.id] as? SourceEditing, host.sourceEditor != nil {
            host.retarget(to: tab.path ?? "")
            contentPaths[tab.id] = tab.path ?? ""
        } else {
            contentViews[tab.id]?.removeFromSuperview()
            contentVCs[tab.id]?.removeFromParent()
            contentVCs[tab.id] = nil
            let v = makeContentView(for: tab, session: session)
            mount(v)
            contentViews[tab.id] = v
            contentPaths[tab.id] = tab.path ?? ""
        }
    }

    private func mount(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentArea.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])
    }

    /// Drop content views for tabs that no longer exist in any session (terminal process is killed
    /// by Session.closeTab/AppModel.closeSession via TerminalStore).
    private func pruneOrphanContent() {
        let live = Set(model.sessions.flatMap { $0.tabs.map(\.id) })
        for id in contentViews.keys where !live.contains(id) {
            contentViews[id]?.removeFromSuperview()
            contentViews[id] = nil
            contentVCs[id]?.removeFromParent()
            contentVCs[id] = nil
            contentPaths[id] = nil
        }
    }

    // MARK: - Quick-terminal bottom dock (VS Code-style panel under the editor)

    /// Show (and return) the empty bottom-dock container, sizing the divider so it gets ~260pt the first
    /// time. The quick-terminal controller mounts its terminal view into the returned container.
    func showBottomDock() -> NSView {
        let dock: NSView
        if let d = bottomDock { dock = d } else {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.backgroundColor = QuickTerminalController.backgroundColor.cgColor   // matches the quick terminal
            d.translatesAutoresizingMaskIntoConstraints = false
            bottomDock = d; dock = d
        }
        if dock.superview == nil {
            centerSplit.addArrangedSubview(dock)
            centerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)    // content flexes on window resize
            centerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)   // dock keeps its height
            view.layoutSubtreeIfNeeded()
            let h = centerSplit.bounds.height
            if h > 0 { centerSplit.setPosition(max(120, h - 260), ofDividerAt: 0) }
        }
        return dock
    }

    /// Collapse the bottom dock (the terminal view stays inside it, just detached from the split).
    /// NOTE: bottom-dock close has an unresolved repaint gap — see the Quick terminal section in FEATURES.md.
    func hideBottomDock() { bottomDock?.removeFromSuperview() }

    /// Restore first-responder to the active tab's content (Claude/terminal or editor) — called when the
    /// quick terminal closes so focus returns to your session/file. The focus change also flushes any
    /// pending layout, settling the content back to full size.
    func focusActiveContent() {
        guard let session = model.activeSession, let tab = session.activeTab else { return }
        switch tab.kind {
        case .claude, .terminal:
            TerminalStore.shared.focus(tab.id)
        case .file:
            (contentVCs[tab.id] as? EditorViewController)?.focusText()
        default:
            break
        }
    }

    // Keep both panes usable while dragging the divider. (Label is `ofSubviewAt` — that's the protocol
    // requirement; `ofDividerAt` silently doesn't conform and never fires.)
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMin, 120)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMax, splitView.bounds.height - 120)
    }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === contentArea   // window resize grows/shrinks the content, keeps the terminal height
    }
}

/// A prominent centered card shown over a terminal whose process has exited (you typed `exit`, Claude quit),
/// so it isn't missed: a dimming scrim + a card with an icon, title, one-line next-step text, and the
/// actions — Restart (accent/primary), Open Terminal (turn a dead Claude tab into a shell; Claude-only), and
/// Close. The scrim is visual only — clicks outside the card pass through so the dead terminal stays
/// scrollable.
final class SessionEndedOverlay: NSView {
    private let card = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Session ended")
    private let subtitle = NSTextField(labelWithString: "")
    private let restartBtn = PointerButton()
    private let terminalBtn = PointerButton()
    private let closeBtn = PointerButton()
    private var onRestart: (() -> Void)?
    private var onOpenTerminal: (() -> Void)?
    private var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.30).cgColor   // scrim → focus on the card

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 0.32, alpha: 1).cgColor
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 22
        card.layer?.shadowOffset = .zero
        card.translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(white: 0.55, alpha: 1)
        if #available(macOS 11.0, *) {
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        }

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1)
        titleLabel.alignment = .center

        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = NSColor(white: 0.62, alpha: 1)
        subtitle.alignment = .center

        func style(_ b: PointerButton, _ title: String, _ sel: Selector) {
            b.title = title
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.target = self
            b.action = sel
        }
        style(restartBtn, "Restart", #selector(restartTapped))
        restartBtn.bezelColor = .controlAccentColor   // primary action — accent-tinted
        style(terminalBtn, "Open Terminal", #selector(terminalTapped))
        style(closeBtn, "Close", #selector(closeTapped))

        let buttons = NSStackView(views: [closeBtn, terminalBtn, restartBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let v = NSStackView(views: [icon, titleLabel, subtitle, buttons])
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 10
        v.setCustomSpacing(6, after: titleLabel)
        v.setCustomSpacing(18, after: subtitle)
        v.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(v)
        addSubview(card)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            v.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            v.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            v.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Clicks on the scrim (anything that isn't the card or its buttons) pass through to the dead terminal,
    /// so it stays scrollable; the card itself stays interactive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func configure(isClaude: Bool, onRestart: @escaping () -> Void,
                   onOpenTerminal: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onRestart = onRestart; self.onOpenTerminal = onOpenTerminal; self.onClose = onClose
        titleLabel.stringValue = isClaude ? "Claude session ended" : "Session ended"
        subtitle.stringValue = isClaude
            ? "Restart to resume the conversation, open a terminal here, or close the tab."
            : "Restart the shell, or close the tab."
        terminalBtn.isHidden = !isClaude
    }

    @objc private func restartTapped() { onRestart?() }
    @objc private func terminalTapped() { onOpenTerminal?() }
    @objc private func closeTapped() { onClose?() }
}
