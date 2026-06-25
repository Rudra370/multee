import AppKit

/// The single main window. Hosts the `WorkspaceViewController` (the split layout). Window frame
/// persists via an autosave name.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let palette: CommandPaletteController
    private let quickTerm: QuickTerminalController
    private let quickAsk: QuickAskController

    init(model: AppModel) {
        let workspace = WorkspaceViewController(model: model)
        self.palette = CommandPaletteController(model: model)
        self.quickTerm = QuickTerminalController(model: model)
        self.quickAsk = QuickAskController(model: model)

        // Root container: update banner (top, collapses to 0 height when hidden) + workspace. The status
        // bar lives at the bottom of the workspace's *center* pane (CenterViewController), not here, so it
        // covers only the file/Claude area and not the sidebar.
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
        window.delegate = self

        // ⌘P quick-open overlays the whole content area (above the banner + workspace).
        palette.attach(to: root)
        CommandPaletteHook.toggle = { [weak palette] in palette?.toggle() }
        CommandPaletteHook.command = { [weak palette] in palette?.toggleCommand() }
        CommandPaletteHook.lineJump = { [weak palette] in palette?.presentLineJump() }

        // ⌃` quick terminal: the centered-overlay mode also mounts into root.
        quickTerm.attach(root: root)
        QuickTerminalHook.toggle = { [weak quickTerm] in quickTerm?.toggle() }
        TerminalStore.shared.onQuickExit = { [weak quickTerm] quickID in quickTerm?.handleShellExit(quickID: quickID) }

        // ⌘/ quick ask: a centered overlay (embedded interactive fork) over the same root.
        quickAsk.attach(root: root)
        QuickAskHook.toggle = { [weak quickAsk] in quickAsk?.toggle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Closing the only window quits the app (`applicationShouldTerminateAfterLastWindowClosed`), so route
    /// the red close button through `terminate` — that hits the unsaved-changes guard in AppDelegate.
    /// Returning false here means the window only closes once the guard (and termination) approve it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
