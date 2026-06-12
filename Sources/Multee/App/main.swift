import AppKit

// Programmatic AppKit entry point (no SwiftUI, no storyboard). The delegate builds the menu and
// main window in `applicationDidFinishLaunching`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
