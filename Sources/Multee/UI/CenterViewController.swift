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
    private var contentViews: [String: NSView] = [:]

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // NB: do NOT set wantsLayer on the terminal's ancestors (root/contentArea). Forcing them
        // layer-backed makes the embedded SwiftTerm view implicitly layer-backed, which the
        // self-screenshot's cacheDisplay path doesn't capture (terminal renders blank in shots).
        // The dark backdrop comes from the window's backgroundColor instead.
        let root = NSView()

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(contentArea)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 34),

            contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
        ])
        self.view = root

        tabBar.onSelect      = { [weak self] id in self?.model.activeSession?.activate(id) }
        tabBar.onClose       = { [weak self] id in self?.model.activeSession?.closeTab(id) }
        tabBar.onNewClaude   = { [weak self] args in
            self?.model.activeSession?.addTab(Tab(kind: .claude, title: "Claude", args: args))
        }
        tabBar.onNewTerminal = { [weak self] in
            self?.model.activeSession?.addTab(Tab(kind: .terminal, title: "Terminal"))
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
        activeSessionObserver = model.activeSession?.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.render() }
        render()
    }

    private func render() {
        pruneOrphanContent()

        guard let session = model.activeSession, let tab = session.activeTab else {
            tabBar.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = model.activeSession == nil
                ? "Open a folder to start  (⌘O)" : "No tabs open"
            contentViews.values.forEach { $0.isHidden = true }
            return
        }

        tabBar.isHidden = false
        emptyLabel.isHidden = true
        tabBar.render(session: session, activeTabID: session.activeTabID)

        // Lazily create the active tab's content view.
        if contentViews[tab.id] == nil {
            let v = makeContentView(for: tab, session: session)
            mount(v)
            contentViews[tab.id] = v
            session.markShown(tab.id)
        }
        for (id, v) in contentViews { v.isHidden = (id != tab.id) }

        if tab.kind == .claude || tab.kind == .terminal {
            DispatchQueue.main.async { TerminalStore.shared.focus(tab.id) }
        }
    }

    private func makeContentView(for tab: Tab, session: Session) -> NSView {
        switch tab.kind {
        case .claude, .terminal:
            return TerminalStore.shared.view(for: tab, cwd: session.url)
        case .file:
            return placeholder("Editor — Phase 3")
        case .diff:
            return placeholder("Diff — Phase 4")
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
        }
    }

    private func placeholder(_ text: String) -> NSView {
        let v = NSView()
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
