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
    private let resourceMonitor = ResourceMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snappier tooltips (default is ~2s). Registered so it doesn't clobber a user override.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])

        Env.bootstrap()                 // compute login PATH once, before anything spawns
        HookServer.shared.start()       // status listener for Claude hooks
        Notifier.shared.start()         // request notification permission; deliver background status pings
        Notifier.shared.onActivate = { [weak self] sessionID, tabID in
            // The session/tab may have been closed since the banner was posted — only switch if it's still open.
            guard let self, let session = self.model.sessions.first(where: { $0.id == sessionID }) else { return }
            self.model.activeSessionID = sessionID
            session.activate(tabID)
        }
        TerminalStore.shared.fontSize = model.settings.fontSize
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()

        windowController = MainWindowController(model: model)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        wireStatusRouting()
        installKeyMonitor()

        // Live resource usage of Multee's own process, shown in the bottom status bar (the bar reads the
        // setting to show/hide; only the *running* monitor produces updates).
        resourceMonitor.onUpdate = { memMB, cpu in ResourceStatus.onUpdate?(memMB, cpu) }
        // Off by default; toggling the setting starts/stops it live.
        model.settings.$showResourceMonitor
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.resourceMonitor.start() } else { self.resourceMonitor.stop() }
            }
            .store(in: &cancellables)

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

        // "Manage Formatters…" (from the format prompt) → open Settings on the Formatters tab.
        FormatterPrompt.openManager = { [weak self] in
            self?.showSettingsWindow()
            self?.settingsWC?.showFormatters()
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
                // Surface only meaningful transitions: a session wanting input, or finishing its work.
                guard old != state, state == .needs || (state == .idle && old == .working) else { continue }
                let settings = self.model.settings
                let sound = { if settings.soundEnabled { NSSound(named: state == .needs ? "Funk" : "Glass")?.play() } }
                // You're "looking at it" only if Multee is frontmost AND this is the active tab of the
                // active session — otherwise (backgrounded, or another session/tab) post a banner.
                let viewingThisTab = NSApp.isActive
                    && self.model.activeSessionID == session.id
                    && session.activeTabID == tabID
                if viewingThisTab {
                    sound()
                } else if settings.notificationsEnabled {
                    let title = session.tabs.first(where: { $0.id == tabID })?.title ?? "Claude"
                    Notifier.shared.post(sessionID: session.id, sessionName: session.name, tabID: tabID,
                                         tabTitle: title, state: state, fallback: sound)
                } else {
                    sound()
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

    /// Quit (⌘Q, menu, or the red close button funnelled through here by MainWindowController): confirm
    /// before discarding unsaved edits across every session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = model.sessions.flatMap { $0.tabs }.filter { $0.dirty }
        return UnsavedGuard.confirmCloseMany(dirty, verb: "quitting") ? .terminateNow : .terminateCancel
    }

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
        let goToFile = fileMenu.addItem(withTitle: "Go to File…", action: #selector(goToFile), keyEquivalent: "p")
        goToFile.target = self
        let cmdPalette = fileMenu.addItem(withTitle: "Command Palette…", action: #selector(commandPalette), keyEquivalent: "p")
        cmdPalette.keyEquivalentModifierMask = [.command, .shift]
        cmdPalette.target = self
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
        editMenu.addItem(.separator())
        // Format moves to ⇧⌥F (matching VS Code) so ⌘⇧F can open Find in Files below.
        let format = editMenu.addItem(withTitle: "Format Document", action: #selector(formatActiveDocument), keyEquivalent: "f")
        format.keyEquivalentModifierMask = [.shift, .option]
        format.target = self

        // Find submenu — routes to the active editor's custom find bar (UI/FindBar), which adds
        // match-case / whole-word / regex toggles the native NSTextFinder can't do.
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findItem.submenu = findMenu
        for i in [findMenu.addItem(withTitle: "Find…", action: #selector(findInFile), keyEquivalent: "f"),
                  findMenu.addItem(withTitle: "Find Next", action: #selector(findNextMatch), keyEquivalent: "g"),
                  findMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevMatch), keyEquivalent: "G"),
                  findMenu.addItem(withTitle: "Use Selection for Find", action: #selector(findUseSelection), keyEquivalent: "e")] {
            i.target = self
        }
        let replaceItem = findMenu.addItem(withTitle: "Find and Replace…", action: #selector(findReplace), keyEquivalent: "f")
        replaceItem.keyEquivalentModifierMask = [.command, .option]
        replaceItem.target = self
        findMenu.addItem(.separator())
        let findInFiles = findMenu.addItem(withTitle: "Find in Files…", action: #selector(findInFilesAction), keyEquivalent: "f")
        findInFiles.keyEquivalentModifierMask = [.command, .shift]
        findInFiles.target = self

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
        guard let s = model.activeSession, let tab = s.activeTab else { return }
        if UnsavedGuard.confirmClose(tab) { s.closeTab(tab.id) }
    }

    @objc private func formatActiveDocument() { ActiveEditor.current?.formatDocument() }

    @objc private func goToFile() { CommandPaletteHook.toggle?() }

    @objc private func commandPalette() { CommandPaletteHook.command?() }

    @objc private func findInFile() { ActiveEditor.current?.showFind() }
    @objc private func findNextMatch() { ActiveEditor.current?.findNext() }
    @objc private func findPrevMatch() { ActiveEditor.current?.findPrevious() }
    @objc private func findUseSelection() { ActiveEditor.current?.useSelectionForFind() }
    @objc private func findReplace() { ActiveEditor.current?.showReplace() }
    @objc private func findInFilesAction() { SidebarSearchHook.reveal?() }
}
