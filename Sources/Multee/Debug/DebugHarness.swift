import AppKit

// DEV-only self-test harness. The dev build reads /tmp/multee-debug.json on launch for
// { shot, state, actions }: it self-screenshots its own window (no Screen-Recording permission),
// dumps its UI state to JSON each tick, and runs scripted actions. Gated on `Bundle.main.isDev`,
// so a stray /tmp file can never affect a real/release Multee.
enum DebugHarness {
    static func start(model: AppModel) {
        guard Bundle.main.isDev,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/multee-debug.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let shot = cfg["shot"] as? String {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in DebugShot.capture(to: shot) }
        }
        if let state = cfg["state"] as? String {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in DebugState.capture(to: state, model) }
        }
        if let actions = cfg["actions"] as? [String] {
            var delay = 0.6
            for action in actions {
                if action.hasPrefix("wait:") { delay += Double(action.dropFirst(5)) ?? 0; continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { DebugAction.run(action, model) }
                delay += 0.9
            }
        }
    }
}

/// Scripted actions that drive the model so features can be verified without a human.
enum DebugAction {
    static func run(_ action: String, _ model: AppModel) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "openRepo":       model.openRepo(arg)
        case "openFile":       model.activeSession?.openFile(arg)
        case "openDiff":       model.activeSession?.openDiff(arg)
        case "newClaude":      model.activeSession?.addTab(Tab(kind: .claude, title: "Claude", args: model.settings.defaultArgs))
        case "forkClaude":     if let s = model.activeSession { s.forkTab(s.activeTabID) }   // ⑂ fork the active Claude tab
        case "setClaudeId":    // simulate the hook capturing a conversation id on the active tab (cid must be a real on-disk transcript)
            if let s = model.activeSession, let i = s.tabs.firstIndex(where: { $0.id == s.activeTabID }) {
                s.tabs[i].claudeSessionId = arg
            }
        case "dumpLaunchArgs":  // write the active tab's computed launch args (resume/fork flags are otherwise invisible)
            if let s = model.activeSession, let t = s.activeTab {
                let args = TerminalStore.shared.debugLaunchArgs(for: t, cwd: s.url)
                try? args.joined(separator: " ").write(toFile: arg.isEmpty ? "/tmp/multee-launchargs.txt" : arg,
                                                        atomically: true, encoding: .utf8)
            }
        case "dumpCid":        // diagnose naming: dump the active tab's captured id + what the title reader sees
            if let s = model.activeSession, let t = s.activeTab {
                let cid = t.claudeSessionId
                let file = cid.flatMap { ClaudeTranscript.file(forSessionId: $0) } ?? "<no file on disk>"
                let title = cid.flatMap { ClaudeTranscript.title(forSessionId: $0) } ?? "<nil>"
                let out = "tabTitle=\(t.title)\nkind=\(t.kind)\ncid=\(cid ?? "<nil — hook never captured>")\nforkParent=\(t.forkParentId ?? "-")\nfile=\(file)\nreadTitle=\(title)\n"
                try? out.write(toFile: arg.isEmpty ? "/tmp/multee-cid.txt" : arg, atomically: true, encoding: .utf8)
            }
        case "applyTitle":     // read the active tab's Claude session name (ai-title) from disk + set it as the title
            if let s = model.activeSession, let i = s.tabs.firstIndex(where: { $0.id == s.activeTabID }),
               let cid = s.tabs[i].claudeSessionId, let t = ClaudeTranscript.title(forSessionId: cid) {
                s.tabs[i].title = t.count > 80 ? String(t.prefix(79)) + "…" : t
            }
        case "quickAskShow":   QuickAskController.current?.show()           // ⌘/ open the embedded Quick Ask panel
        case "quickAskHide":   QuickAskController.current?.hide()           // hide the panel (the fork PTY persists)
        case "quickAskNew":    QuickAskController.current?.newThread()      // "New" — drop the fork, start a fresh one
        case "quickAskMode":   QuickAskController.current?.debugMode(arg == "context")   // Context|Blank toggle
        case "quickAskSend":   QuickAskController.current?.debugSend(arg)   // type a question into the embedded terminal
        case "quickAskOpenAsTab": QuickAskController.current?.openAsTab()   // ↗ promote the fork to a real Claude tab
        case "dumpQuickAsk":   // panel state + launch args (proves fork flags) + the terminal's rendered text
            let dump = QuickAskController.current?.debugDump() ?? "<no quick ask>"
            try? dump.write(toFile: arg.isEmpty ? "/tmp/multee-quickask.txt" : arg, atomically: true, encoding: .utf8)
        case "dockerToggle":   DockerHook.toggle?()                                 // status-bar Docker icon → bottom dock
        case "dockerForceAvailable":   // 1|0 = force the daemon available/unavailable (test the icon show/hide path)
            DockerPanelController.current?.debugForceAvailable(arg == "1" ? true : (arg == "0" ? false : nil))
        case "dockerPick":     DockerPanelController.current?.togglePick(arg)       // toggle a compose file in the selection
        case "dockerPickerShow": DockerPanelController.current?.debugShowPicker()   // open the picker popover (for the screenshot)
        case "dockerRefresh":  DockerPanelController.current?.debugRefresh()        // reload the service list (config + ps)
        case "dockerTab":      DockerPanelController.current?.debugSetTab(arg == "volumes" ? 1 : 0)  // Services|Volumes toggle
        case "dockerStart":    DockerPanelController.current?.runServiceAction(arg, .start)   // per-service Start (up -d <svc>)
        case "dockerStop":     DockerPanelController.current?.runServiceAction(arg, .stop)
        case "dockerRestart":  DockerPanelController.current?.runServiceAction(arg, .restart)
        case "dockerUp":       DockerPanelController.current?.runProjectAction(.up)
        case "dockerStopAll":  DockerPanelController.current?.runProjectAction(.stop)
        case "dockerRestartAll": DockerPanelController.current?.runProjectAction(.restart)
        case "dockerDown":     DockerPanelController.current?.runProjectAction(.down)         // light confirm → DockerConfirm
        case "dockerBuild":    DockerPanelController.current?.runProjectAction(.build)        // build all images (no start)
        case "dockerSvcBuild": DockerPanelController.current?.runServiceAction(arg, .build)   // build one service (no start)
        case "dockerStartBuild": DockerPanelController.current?.runServiceAction(arg, .startBuild)  // up -d --build <svc>
        case "dockerPull":     DockerPanelController.current?.runProjectAction(.pull)         // pull all images
        case "dockerSvcPull":  DockerPanelController.current?.runServiceAction(arg, .pull)    // pull one service's image
        case "dockerActing":   DockerPanelController.current?.debugSetActing(arg.isEmpty ? nil : arg)  // force a row's spinner (screenshot)
        case "dockerOpenPort": DockerPanelController.current?.openPort(arg)                  // open http://localhost:<host>
        case "dockerConfirm":  DockerConfirm.debugResponse = (arg == "ok")                    // canned answer for the confirm dialog
        case "dockerOverlayShow":   DockerPanelController.current?.debugShowOverlay()         // reveal the action peek overlay
        case "dockerOverlayOpenAsTab": DockerPanelController.current?.debugOpenAsTab()        // promote the action PTY to a tab
        case "dockerLogs":     DockerPanelController.current?.openLogs(service: arg)          // per-service logs → new tab
        case "dockerLogsAll":  DockerPanelController.current?.openLogs(service: nil)          // all-services logs → new tab
        case "dockerExec":     DockerPanelController.current?.openExec(service: arg)          // shell into a running container → new tab
        case "dockerAddFile":  DockerPanelController.current?.addComposeFile(path: arg)       // add an odd-named compose file (bypasses the open panel)
        case "dockerVolumes":  DockerPanelController.current?.loadVolumes()                   // (re)load the volume list
        case "dockerVolSize":  DockerPanelController.current?.loadVolumeSize(arg)             // compute one volume's size
        case "dockerVolRemove": DockerPanelController.current?.removeVolume(arg)              // delete a volume (strong confirm)
        case "dumpDocker":     // availability + panel/dock state
            let dump = DockerPanelController.current?.debugDump() ?? "<no docker>"
            try? dump.write(toFile: arg.isEmpty ? "/tmp/multee-docker.txt" : arg, atomically: true, encoding: .utf8)
        case "newTerminal":    model.activeSession?.addTab(Tab(kind: .terminal, title: "Terminal"))
        case "newProject":   // path|git — create a folder (optionally git init) + open it (skips the HID save panel)
            let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
            NewProject.create(at: p.first ?? "", initGit: p.count > 1 && p[1] == "git", model: model)
        case "closeActiveTab": if let s = model.activeSession { s.closeTab(s.activeTabID) }
        case "activateTab":    if let s = model.activeSession, let i = Int(arg), s.tabs.indices.contains(i) { s.activate(s.tabs[i].id) }
        case "renderAttentionMenu": AttentionMenu.debugRender(to: arg.isEmpty ? "/tmp/attention-menu.png" : arg)
        case "tabRestart":      if let s = model.activeSession { s.restartTab(s.activeTabID) }   // "Session ended" bar → Restart
        case "tabToTerminal":   if let s = model.activeSession { s.convertToTerminal(s.activeTabID) }  // → Open Terminal
        case "quickToggle":     QuickTerminalHook.toggle?()                                   // ⌃` quick terminal
        case "quickMode":       model.settings.quickTermMode = Settings.QuickTermMode(rawValue: arg) ?? .floating
        case "quickSend":       if let id = QuickTerminalController.current?.debugActiveID { TerminalStore.shared.send(id, arg) }
        case "quickNew":        QuickTerminalController.current?.debugNewTerminal()           // + (spawn another shell)
        case "quickActivate":   QuickTerminalController.current?.debugSelect((Int(arg) ?? 1) - 1)  // 1-based chip index
        case "quickClose":      QuickTerminalController.current?.debugClose((Int(arg) ?? 1) - 1)   // 1-based chip index
        case "quickOpenAsTab":  QuickTerminalController.current?.debugOpenAsTab()             // ↗ promote active shell
        case "newTermShortcut": NewItemHook.newTerminal?()        // ⌃⇧`: quick shell if panel open, else terminal tab
        case "newClaudeShortcut": NewItemHook.newClaude?()        // ⌘⇧C: new Claude tab (default args)
        case "newFile":         NewItemHook.newFile?()           // ⌘N: new blank untitled editor tab
        case "editorSaveAs":    ActiveEditor.current?.debugSaveAs(arg)   // save the untitled tab to a path (panel is HID)
        case "editorLineColors":   // from-to → dump applied fg colour per line (highlighter-desync diagnosis)
            let p = arg.split(separator: "-").compactMap { Int($0) }
            if p.count == 2, let lines = ActiveEditor.current?.debugLineColors(p[0], p[1]) {
                try? lines.joined(separator: "\n").write(toFile: "/tmp/multee-colordump.txt", atomically: true, encoding: .utf8)
            }
        case "editorColorRuns":   // comma-separated line numbers → per-char colour runs (string-open diagnosis)
            let lines = arg.split(separator: ",").compactMap { Int($0) }
            let dump = lines.map { "L\($0): " + (ActiveEditor.current?.debugColorRuns($0) ?? "?") }.joined(separator: "\n")
            try? dump.write(toFile: "/tmp/multee-colorruns.txt", atomically: true, encoding: .utf8)
        case "showShortcuts":   ShortcutsWindowController.shared.show()
        case "renderShortcuts": ShortcutsWindowController.shared.debugRender(to: arg.isEmpty ? "/tmp/shortcuts.png" : arg)
        case "unsavedResp":   // canned answer for the close/quit guard (modal can't be clicked in harness)
            switch arg { case "save": UnsavedGuard.debugResponse = .save
                         case "dontSave", "discard": UnsavedGuard.debugResponse = .dontSave
                         case "cancel": UnsavedGuard.debugResponse = .cancel
                         default: UnsavedGuard.debugResponse = nil }
        case "closeTabGuarded":   // exercises the real guarded close path (⌘W / close button)
            if let s = model.activeSession, let t = s.activeTab, UnsavedGuard.confirmClose(t) { s.closeTab(t.id) }
        case "closeSession":   if let s = model.activeSession { model.closeSession(s.id) }
        case "openSettings":   model.showSettings = true
        case "openFormatters": FormatterPrompt.openManager?()
        case "sendText":  if let s = model.activeSession { TerminalStore.shared.send(s.activeTabID, arg) }
        case "sendEnter": if let s = model.activeSession { TerminalStore.shared.send(s.activeTabID, "\r") }
        case "scroll":
            let p = arg.split(separator: ":").map(String.init)
            let up = (p.first ?? "down") == "up"
            let lines = p.count > 1 ? (Int(p[1]) ?? 3) : 3
            if let s = model.activeSession { TerminalStore.shared.debugScroll(s.activeTabID, up: up, lines: lines) }
        case "setStatus":
            if let s = model.activeSession {
                s.tabStatus[s.activeTabID] = arg == "working" ? .working : arg == "needs" ? .needs
                    : arg == "done" ? .done : .idle
            }
        case "hookStatus":   // index:state — inject a hook event through the real routing + debounce
            let p = arg.split(separator: ":").map(String.init)
            if p.count == 2, let i = Int(p[0]), let s = model.activeSession, s.tabs.indices.contains(i) {
                let st: ClaudeState = p[1] == "working" ? .working : p[1] == "needs" ? .needs : .idle
                HookServer.shared.onStatus?(s.tabs[i].id, st)
            }
        case "editorType": ActiveEditor.current?.debugAppend(arg)
        case "editorSave":  ActiveEditor.current?.save()
        case "editorFormat": ActiveEditor.current?.formatDocument()
        case "fmtInstall":   FormatterInstall.run?(arg)   // exercises the [Install] → Terminal-tab path
        case "editorScroll": ActiveEditor.current?.debugScroll(lines: Int(arg) ?? 30)
        case "editorEol":        ActiveEditor.current?.debugConvertEol(arg)   // LF | CRLF
        case "editorIndent":     ActiveEditor.current?.convertIndentation(to: arg)   // Tabs | Spaces: N
        case "editorLang":       ActiveEditor.current?.setLanguageOverride(arg.isEmpty ? nil : arg)
        case "paletteLineJump":  CommandPaletteHook.lineJump?()
        case "gitCheckout":      if let s = model.activeSession { _ = Git.checkout(s.url, arg); s.gitBranch = Git.branch(s.url) }
        case "gitBranchNew":     if let s = model.activeSession { _ = Git.createBranch(s.url, arg); s.gitBranch = Git.branch(s.url) }
        case "gitBranchDel":     if let s = model.activeSession { _ = Git.deleteBranch(s.url, arg, force: false) }
        case "editorFind":       ActiveEditor.current?.debugFind(arg)
        case "editorFindToggle": ActiveEditor.current?.debugFindToggle(arg)   // case | word | regex
        case "editorFindNext":   ActiveEditor.current?.debugFindNext()
        case "editorReplaceShow": ActiveEditor.current?.debugReplaceShow()
        case "editorReplaceAll": ActiveEditor.current?.debugReplaceAll(arg)
        case "editorReplaceOne": ActiveEditor.current?.debugReplaceOne(arg)
        case "sourceMode":   // flip a markdown/SVG viewer's Preview/Image ↔ Source toggle (arg "1"=source)
            let show = arg == "1" || arg == "source"
            (ActiveEditor.current?.parent as? MarkdownViewController)?.setSourceVisible(show)
            (ActiveEditor.current?.parent as? ImageViewController)?.setSourceVisible(show)
        case "setFont":     model.settings.fontSize = Double(arg) ?? 13
        case "treeNewFile":   FileTreeViewController.current?.debugCreate(name: arg, folder: false)
        case "treeNewFolder": FileTreeViewController.current?.debugCreate(name: arg, folder: true)
        case "treeBeginFile": FileTreeViewController.current?.beginNewFile()
        case "treeExpandAll": FileTreeViewController.current?.debugExpandAll()
        case "treeCollapseAll": FileTreeViewController.current?.collapseAll()
        case "treeRename":
            let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if p.count == 2 { FileTreeViewController.current?.debugRename(rel: p[0], to: p[1]) }
        case "treeDelete": FileTreeViewController.current?.debugDelete(rel: arg)
        case "paletteOpen":  CommandPaletteHook.toggle?()
        case "paletteCommands": CommandPaletteHook.command?()
        case "paletteType":  CommandPaletteController.current?.debugType(arg)
        case "paletteDown":  CommandPaletteController.current?.debugMove(1)
        case "paletteUp":    CommandPaletteController.current?.debugMove(-1)
        case "paletteEnter": CommandPaletteController.current?.debugOpenSelected()
        case "paletteClose": CommandPaletteController.current?.dismiss()
        case "sidebarMode":  SidebarViewController.current?.debugSelectMode(Int(arg) ?? 0)   // 0 Files / 1 Changes / 2 Search
        case "revealSearch":  SidebarSearchHook.reveal?()                         // ⌘⇧F: reveal the sidebar Search
        case "sessionsToggle": SidebarCollapseHook.toggle?()                      // collapse/expand the SESSIONS panel
        case "searchOpenAsTab": SearchViewController.current?.debugOpenAsTab()    // sidebar "Open as Tab" button
        case "openAt":          // file|line — open a file at a line (a search-result click; tests markdown→Source)
            let p = arg.split(separator: "|").map(String.init)
            if p.count == 2, let line = Int(p[1]) { FileNavigator.openAt?(p[0], line) }
        case "openSearchTab": model.activeSession?.openSearch()
        case "projectSearchTab": SearchViewController.currentTab?.debugRun(arg)   // search inside the standalone tab
        case "projectSearch": SearchViewController.current?.debugRun(arg)   // run a sidebar search synchronously
        case "searchOpenFirst": SearchViewController.current?.debugOpenFirst()   // open the first hit at its line
        default: break
        }
    }
}

/// Writes the app's UI state to JSON each tick so the assistant can assert on values.
enum DebugState {
    static func capture(to path: String, _ model: AppModel) {
        var root: [String: Any] = [:]
        if let ed = ActiveEditor.current { root["editorDirty"] = ed.isDirty; root["editorTextLen"] = ed.debugText.count; root["editorCaretLine"] = ed.debugCaretLine; root["editorSelText"] = ed.debugSelectedText; root["findCount"] = ed.debugFindCount; root["findCurrent"] = ed.debugFindCurrent }
        root["selfMemMB"] = Int(ResourceMonitor.memoryMB())
        root["findPanelsVisible"] = NSApp.windows.filter { $0 is FindPanel && $0.isVisible }.count
        if let ed = ActiveEditor.current { root["editorFocused"] = ed.debugIsFocused }
        if let p = CommandPaletteController.current?.debugState() { root["palette"] = p }
        if let s = SearchViewController.current?.debugState() { root["search"] = s }
        if let s = SearchViewController.currentTab?.debugState() { root["searchTab"] = s }
        if let a = AttentionItem.current?.debugState() { root["attention"] = a }
        if let q = QuickTerminalController.current?.debugState() { root["quickTerminal"] = q }
        if let d = DockerPanelController.current?.debugStateDict() { root["docker"] = d }
        root["activeSession"] = model.activeSession?.name ?? NSNull()
        root["branch"] = model.activeSession?.gitBranch ?? NSNull()
        if let ed = ActiveEditor.current {
            let lc = ed.cursorLineColumn()
            root["status"] = ["ln": lc.line, "col": lc.column, "eol": ed.lineEnding,
                              "indent": ed.indentStyle, "lang": ed.languageDisplayName,
                              "hasCRLF": ed.debugHasCRLF]
        }
        root["activeSessionPath"] = model.activeSession?.url ?? NSNull()
        root["sessions"] = model.sessions.map { s in
            ["name": s.name, "path": s.url, "active": s.id == model.activeSessionID,
             "tabCount": s.tabs.count, "status": s.status.rawValue]
        }
        if let s = model.activeSession {
            root["tabs"] = s.tabs.map { t in
                ["kind": t.kind.rawValue, "title": t.title, "active": t.id == s.activeTabID,
                 "status": (s.tabStatus[t.id] ?? .idle).rawValue, "exited": t.exited]
            }
            if let t = s.activeTab {
                var at: [String: Any] = ["kind": t.kind.rawValue, "title": t.title,
                                         "status": (s.tabStatus[t.id] ?? .idle).rawValue, "exited": t.exited]
                if t.kind == .claude || t.kind == .terminal,
                   let ts = TerminalStore.shared.debugState(t.id) {
                    at["terminal"] = ts
                    if let text = TerminalStore.shared.debugText(t.id) {
                        at["terminalText"] = String(text.suffix(2000))   // last visible output
                    }
                }
                root["activeTab"] = at
            }
        }
        // Layout diagnostic: frames of the tab bar + workspace backdrop, in window coords.
        if let win = NSApp.mainWindow ?? NSApp.windows.first, let cv = win.contentView {
            var frames: [String: String] = [:]
            walk(cv, into: &frames)
            if !frames.isEmpty { root["layout"] = frames }
        }

        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func walk(_ v: NSView, into out: inout [String: String]) {
        let label: String? = v is TabBarView ? "tabBar"
            : v is MulteeTerminalView ? "terminal"
            : v is PointerOutlineView ? "tree" : nil
        if let label, out[label] == nil {
            let r = v.convert(v.bounds, to: nil)
            var info = "x\(Int(r.minX)) y\(Int(r.minY)) w\(Int(r.width)) h\(Int(r.height)) hidden\(v.isHidden)"
            if let bar = v as? NSView, label == "tabBar" {
                let chips = countChips(bar)
                info += " chips\(chips)"
            }
            if let ov = v as? NSOutlineView {
                let clipW = ov.enclosingScrollView?.contentView.bounds.width ?? -1
                info += " rows\(ov.numberOfRows) clipW\(Int(clipW)) frameW\(Int(ov.frame.width))"
            }
            out[label] = info
        }
        v.subviews.forEach { walk($0, into: &out) }
    }

    private static func countChips(_ v: NSView) -> Int {
        var n = v is TabChipView ? 1 : 0
        v.subviews.forEach { n += countChips($0) }
        return n
    }
}

/// Renders the main window's content view to a PNG (no Screen-Recording permission needed).
enum DebugShot {
    static func capture(to path: String) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        guard let window, let view = window.contentView,
              view.bounds.width > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
