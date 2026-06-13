import AppKit
import Combine

/// The workspace pane: a tab bar on top and the active tab's content below. Tab content views stay
/// mounted (hidden) so terminals keep running across switches; content is lazily created the first
/// time a tab becomes active (so a restored session only spawns its active tab).
final class CenterViewController: NSViewController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var activeSessionObserver: AnyCancellable?

    private let tabBar = TabBarView()
    private let contentArea = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Open a folder to start  (⌘O)")
    private let openButton = PointerButton()
    private var emptyStack: NSView?
    private var contentViews: [String: NSView] = [:]
    private var contentVCs: [String: NSViewController] = [:]   // VC-backed content (editor, diff)

    init(model: AppModel) {
        self.model = model
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

        // Vertical stack guarantees tabBar (fixed height) sits ABOVE a filling contentArea with no
        // overlap — manual top/bottom constraints were collapsing the bar to zero height.
        let vstack = NSStackView(views: [tabBar, contentArea])
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

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: root.topAnchor),
            vstack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vstack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            tabBar.heightAnchor.constraint(equalToConstant: 34),
            tabBar.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            contentArea.widthAnchor.constraint(equalTo: vstack.widthAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
        ])
        self.view = root

        tabBar.onSelect      = { [weak self] id in self?.model.activeSession?.activate(id) }
        tabBar.onClose       = { [weak self] id in self?.model.activeSession?.closeTab(id) }
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
            return
        }

        emptyStack?.isHidden = true

        // Lazily create the active tab's content view.
        if contentViews[tab.id] == nil {
            let v = makeContentView(for: tab, session: session)
            mount(v)
            contentViews[tab.id] = v
            session.markShown(tab.id)
        }
        for (id, v) in contentViews { v.isHidden = (id != tab.id) }

        ActiveEditor.current = (tab.kind == .file) ? (contentVCs[tab.id] as? EditorViewController) : nil

        if tab.kind == .claude || tab.kind == .terminal {
            DispatchQueue.main.async { TerminalStore.shared.focus(tab.id) }
        }
    }

    private func makeContentView(for tab: Tab, session: Session) -> NSView {
        switch tab.kind {
        case .claude, .terminal:
            return TerminalStore.shared.view(for: tab, cwd: session.url)
        case .file:
            // A .file tab picks its viewer by extension: images render, markdown previews, the rest edit.
            if ImageViewController.handles(tab.path) {
                let vc = ImageViewController(path: tab.path ?? "")
                addChild(vc)
                contentVCs[tab.id] = vc
                return vc.view
            }
            if MarkdownViewController.handles(tab.path) {
                let vc = MarkdownViewController(path: tab.path ?? "")
                addChild(vc)
                contentVCs[tab.id] = vc
                return vc.view
            }
            let vc = EditorViewController(path: tab.path ?? "", settings: model.settings,
                                          onDirty: { [weak session] dirty in session?.setDirty(tab.id, dirty) })
            addChild(vc)
            contentVCs[tab.id] = vc
            return vc.view
        case .diff:
            let vc = DiffViewController(repo: session.url, path: tab.path ?? "",
                                       onOpenFile: { [weak session] in session?.openFile(tab.path ?? "") })
            addChild(vc)
            contentVCs[tab.id] = vc
            return vc.view
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
        }
    }

    private func placeholder(_ text: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }
}
