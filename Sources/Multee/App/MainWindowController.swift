import AppKit

/// The single main window. Hosts the `WorkspaceViewController` (the split layout). Window frame
/// persists via an autosave name.
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let workspace = WorkspaceViewController(model: model)

        // Root container: update banner (top, collapses to 0 height when hidden) + workspace.
        let container = NSViewController()
        let root = NSView()
        let banner = UpdateBannerView(updates: Updates.shared, model: model)
        banner.translatesAutoresizingMaskIntoConstraints = false
        workspace.view.translatesAutoresizingMaskIntoConstraints = false
        container.addChild(workspace)
        root.addSubview(banner)
        root.addSubview(workspace.view)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspace.view.topAnchor.constraint(equalTo: banner.bottomAnchor),
            workspace.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            workspace.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspace.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        container.view = root

        let window = NSWindow(contentViewController: container)
        window.title = "Multee"
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)   // workspace backdrop (no layer on terminal ancestors)
        // NB: NOT .fullSizeContentView — that draws content under the title bar, hiding the tab bar
        // and the Files/Changes toggle behind it.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.setFrameAutosaveName("MulteeMainWindow")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
