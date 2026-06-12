import AppKit

extension Bundle {
    /// Dev build = bundle id ends in `.dev` (set by build.sh for the debug "Multee Dev" app). Used
    /// to gate the debug harness so a stray /tmp file can never affect a real/release Multee.
    var isDev: Bool { (bundleIdentifier ?? "").hasSuffix(".dev") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windowController: MainWindowController!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Env.bootstrap()                 // compute login PATH once, before anything spawns
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()

        windowController = MainWindowController(model: model)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        DebugHarness.start(model: model)   // dev-only (inert in release)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Key handling (Cmd+W close tab, Cmd+/- font)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            // Cmd+W is the "Close Tab" menu item. Cmd+/- have no menu item yet, so handle here.
            case "=", "+":
                self.model.settings.bumpFont(1); return nil
            case "-", "_":
                self.model.settings.bumpFont(-1); return nil
            default:
                break
            }
            return event
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Multee",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Multee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder), keyEquivalent: "o")
        open.target = self
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab), keyEquivalent: "w")
        closeTab.target = self

        // Edit menu (first-responder actions so text editing + copy/paste work in NSTextView/terminal)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { model.openRepo(url.path) }
    }

    @objc private func openSettings() { model.showSettings = true }

    @objc private func closeActiveTab() {
        if let s = model.activeSession, !s.tabs.isEmpty { s.closeTab(s.activeTabID) }
    }
}
