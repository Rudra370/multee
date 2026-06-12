import AppKit

/// The single main window. Hosts the `WorkspaceViewController` (the split layout). Window frame
/// persists via an autosave name.
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let workspace = WorkspaceViewController(model: model)
        let window = NSWindow(contentViewController: workspace)
        window.title = "Multee"
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)   // workspace backdrop (no layer on terminal ancestors)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.setFrameAutosaveName("MulteeMainWindow")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
