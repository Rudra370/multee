import AppKit
import Combine

extension Bundle {
    /// Dev build = bundle id ends in `.dev` (set by build.sh for the debug "Multee Dev" app). Used
    /// to gate the debug harness so a stray /tmp file can never affect a real/release Multee.
    var isDev: Bool { (bundleIdentifier ?? "").hasSuffix(".dev") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windowController: MainWindowController!
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWC: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Env.bootstrap()                 // compute login PATH once, before anything spawns
        HookServer.shared.start()       // status listener for Claude hooks
        TerminalStore.shared.fontSize = model.settings.fontSize
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()

        windowController = MainWindowController(model: model)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        wireStatusRouting()
        installKeyMonitor()

        // Settings window on demand.
        model.$showSettings
            .filter { $0 }
            .sink { [weak self] _ in self?.showSettingsWindow() }
            .store(in: &cancellables)

        // Update check (release builds only — the dev build is always "behind" latest).
        if !Bundle.main.isDev {
            Updates.shared.detectBrew()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updates.shared.check() }
        }

        DebugHarness.start(model: model)   // dev-only (inert in release)
    }

    private func showSettingsWindow() {
        if settingsWC == nil { settingsWC = SettingsWindowController(settings: model.settings) }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        model.showSettings = false
    }

    /// Route Claude status pings to the owning session's tab + play the attention/completion sound;
    /// remember the conversation id for `--resume`; keep terminals in sync with the shared font size.
    private func wireStatusRouting() {
        HookServer.shared.onStatus = { [weak self] tabID, state in
            guard let self else { return }
            for session in self.model.sessions where session.tabs.contains(where: { $0.id == tabID }) {
                let old = session.tabStatus[tabID] ?? .idle
                session.tabStatus[tabID] = state
                if self.model.settings.soundEnabled, old != state,
                   state == .needs || (state == .idle && old == .working) {
                    NSSound(named: state == .needs ? "Funk" : "Glass")?.play()
                }
            }
        }
        HookServer.shared.onClaudeId = { [weak self] tabID, cid in
            guard let self else { return }
            for session in self.model.sessions {
                if let i = session.tabs.firstIndex(where: { $0.id == tabID }),
                   session.tabs[i].claudeSessionId != cid {
                    session.tabs[i].claudeSessionId = cid   // triggers debounced auto-save
                }
            }
        }
        model.settings.$fontSize
            .sink { TerminalStore.shared.applyFont(size: $0) }
            .store(in: &cancellables)
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
        let check = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
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

    @objc private func checkForUpdates() { Updates.shared.check(force: true) }

    @objc private func closeActiveTab() {
        if let s = model.activeSession, !s.tabs.isEmpty { s.closeTab(s.activeTabID) }
    }
}
