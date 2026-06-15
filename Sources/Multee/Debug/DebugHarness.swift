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
        case "newTerminal":    model.activeSession?.addTab(Tab(kind: .terminal, title: "Terminal"))
        case "closeActiveTab": if let s = model.activeSession { s.closeTab(s.activeTabID) }
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
                s.tabStatus[s.activeTabID] = arg == "working" ? .working : arg == "needs" ? .needs : .idle
            }
        case "editorType": ActiveEditor.current?.debugAppend(arg)
        case "editorSave":  ActiveEditor.current?.save()
        case "editorFormat": ActiveEditor.current?.formatDocument()
        case "fmtInstall":   FormatterInstall.run?(arg)   // exercises the [Install] → Terminal-tab path
        case "editorScroll": ActiveEditor.current?.debugScroll(lines: Int(arg) ?? 30)
        case "sourceMode":   // flip a markdown/SVG viewer's Preview/Image ↔ Source toggle (arg "1"=source)
            let show = arg == "1" || arg == "source"
            (ActiveEditor.current?.parent as? MarkdownViewController)?.debugSetSourceVisible(show)
            (ActiveEditor.current?.parent as? ImageViewController)?.debugSetSourceVisible(show)
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
        case "paletteType":  CommandPaletteController.current?.debugType(arg)
        case "paletteDown":  CommandPaletteController.current?.debugMove(1)
        case "paletteUp":    CommandPaletteController.current?.debugMove(-1)
        case "paletteEnter": CommandPaletteController.current?.debugOpenSelected()
        case "paletteClose": CommandPaletteController.current?.dismiss()
        default: break
        }
    }
}

/// Writes the app's UI state to JSON each tick so the assistant can assert on values.
enum DebugState {
    static func capture(to path: String, _ model: AppModel) {
        var root: [String: Any] = [:]
        if let ed = ActiveEditor.current { root["editorDirty"] = ed.isDirty; root["editorTextLen"] = ed.debugText.count; root["editorCaretLine"] = ed.debugCaretLine }
        root["selfMemMB"] = Int(ResourceMonitor.memoryMB())
        if let p = CommandPaletteController.current?.debugState() { root["palette"] = p }
        root["activeSession"] = model.activeSession?.name ?? NSNull()
        root["activeSessionPath"] = model.activeSession?.url ?? NSNull()
        root["sessions"] = model.sessions.map { s in
            ["name": s.name, "path": s.url, "active": s.id == model.activeSessionID,
             "tabCount": s.tabs.count, "status": s.status.rawValue]
        }
        if let s = model.activeSession {
            root["tabs"] = s.tabs.map { t in
                ["kind": t.kind.rawValue, "title": t.title, "active": t.id == s.activeTabID,
                 "status": (s.tabStatus[t.id] ?? .idle).rawValue]
            }
            if let t = s.activeTab {
                var at: [String: Any] = ["kind": t.kind.rawValue, "title": t.title,
                                         "status": (s.tabStatus[t.id] ?? .idle).rawValue]
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
