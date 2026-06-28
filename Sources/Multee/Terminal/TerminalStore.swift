import AppKit
import SwiftTerm

/// One persistent PTY view per tab id — the process stays alive across tab/session switches, so
/// nothing is killed just by looking away. Keyed by the tab's `String` id.
final class TerminalStore {
    static let shared = TerminalStore()

    private var views: [String: MulteeTerminalView] = [:]
    /// Current shared font size (seeded from Settings); new terminals use it.
    var fontSize: Double = 13

    /// A tab's process exited (typed `exit` / Claude quit) — argument is the tab id. Wired by AppDelegate to
    /// flag the tab so the UI shows the "Session ended" bar. `onQuickExit` is the quick-terminal equivalent
    /// (argument is the full quick-terminal id, `__quick__<sid>::<n>`).
    var onExit: ((String) -> Void)?
    var onQuickExit: ((String) -> Void)?

    /// One app-wide scroll-wheel monitor shared by every terminal (installed lazily on first
    /// terminal). It routes each event to the single terminal under the cursor via window
    /// hit-testing — instead of each terminal installing its own monitor and racing to claim events
    /// (which let a hidden background instance swallow scrolls meant for the visible one).
    private var scrollMonitor: Any?

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window,
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let v = view {
                if let term = v as? MulteeTerminalView {
                    return term.handleWheel(event) ? nil : event   // swallow only if it scrolled
                }
                view = v.superview
            }
            return event   // not over a terminal — leave editor/tree scrolling alone
        }
    }

    /// Restyle every live terminal when the shared font size changes.
    func applyFont(size: Double) {
        fontSize = size
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        for v in views.values { v.font = f }
    }

    /// Does Claude still have a saved transcript for this conversation?
    /// Claude stores transcripts at `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`, where it
    /// encodes the path by replacing `/`, `_`, `.` (and other non-alphanumerics) with `-`. Rather than
    /// mirror that exactly (we got it wrong before — only `/` was replaced, so any repo path with `_`
    /// or `.` failed to resume), we just look up the transcript by its unique id under *any* project
    /// dir. The id is a UUID, so the directory name doesn't matter — encoding-proof.
    private static func conversationExists(sessionId: String) -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return false }
        let file = "\(sessionId).jsonl"
        return dirs.contains {
            FileManager.default.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent(file).path)
        }
    }

    /// Claude's "continue / resume" flags. Passing one for a folder Claude has never seen errors out with
    /// "no conversation to continue", so we drop them when there's nothing to continue (see `hasConversation`).
    private static let resumeFlags: Set<String> = ["--continue", "-c", "--resume", "-r"]

    /// Does Claude have any saved conversation for this working directory (so `--continue` would succeed)?
    /// Claude keys transcripts by an encoded cwd — every non-alphanumeric char becomes `-`
    /// (`/Users/rudra/Claude/multee` → `-Users-rudra-Claude-multee`). If that project dir has any `.jsonl`,
    /// there's something to continue. A wrong guess only ever means "launch fresh", never a dead tab.
    private static func hasConversation(forCwd cwd: String) -> Bool {
        func isAlnum(_ c: Character) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
        }
        let encoded = String(cwd.map { isAlnum($0) ? $0 : "-" })
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// The shell/args/env to launch a tab's process. Re-derived from the tab's CURRENT kind/args on every
    /// `view(for:)`, so a rebuild (Restart / convert-to-terminal) picks up flag/kind changes.
    private func launchSpec(for tab: Tab, cwd: String) -> (exe: String, args: [String], env: [String]) {
        switch tab.kind {
        case .claude:
            let exe = Env.resolve("claude")
            // Resume the saved conversation only if Claude's transcript for it still exists; else
            // start fresh (a wrong guess just means "fresh", never a dead tab).
            let userArgs = tab.args.split(separator: " ").map(String.init)
            let base: [String]
            if let parent = tab.forkParentId, tab.claudeSessionId == nil, Self.conversationExists(sessionId: parent) {
                // A freshly-forked tab that hasn't captured its own id yet → resume the source conversation
                // as a NEW session (`--fork-session`). Once the hook reports this fork's own id, the branch
                // above takes over and a Restart resumes the fork in place (no second fork).
                base = userArgs.filter { !Self.resumeFlags.contains($0) } + ["--resume", parent, "--fork-session"]
            } else if let cid = tab.claudeSessionId, Self.conversationExists(sessionId: cid) {
                base = userArgs.filter { !Self.resumeFlags.contains($0) } + ["--resume", cid]
            } else if userArgs.contains(where: Self.resumeFlags.contains), !Self.hasConversation(forCwd: cwd) {
                // A default like `--continue` would fail on a folder Claude has never seen ("no conversation
                // to continue") and kill the tab. Drop it so a brand-new project just starts fresh.
                base = userArgs.filter { !Self.resumeFlags.contains($0) }
            } else {
                base = userArgs
            }
            let env = Env.array(extra: ["MULTEE_SESSION_ID": tab.id,
                                        "MULTEE_HOOK_PORT": String(HookServer.shared.port)])
            return (exe, base + ["--settings", Hooks.json], env)
        case .terminal, .file, .diff, .search:   // only .terminal reaches here (file/diff/search use their own views)
            let exe = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // A terminal tab created with an initial command (e.g. "Install" a formatter) runs it, then
            // drops to an interactive login shell so its output stays visible.
            let args = tab.args.isEmpty ? ["-l"] : ["-l", "-c", "\(tab.args); exec \(exe) -l"]
            return (exe, args, Env.array())
        }
    }

    /// Dev-only: the exact args `claude`/the shell would launch with for this tab, without spawning it.
    /// Used by the debug harness to verify fork/resume flag construction (which is otherwise invisible —
    /// it lives in CLI flags, not in any view the screenshot can capture). See `dumpLaunchArgs` action.
    func debugLaunchArgs(for tab: Tab, cwd: String) -> [String] { launchSpec(for: tab, cwd: cwd).args }

    /// Does Claude still have a forkable transcript for this conversation id? (Quick Ask uses this to decide
    /// whether a Context fork is possible, or it must fall back to Blank.)
    func canFork(sessionId: String) -> Bool { Self.conversationExists(sessionId: sessionId) }

    /// Get (or lazily spawn) the terminal view for a tab. `cwd` is the session's repo root.
    func view(for tab: Tab, cwd: String) -> MulteeTerminalView {
        installScrollMonitorIfNeeded()
        if let v = views[tab.id] { return v }

        let tv = MulteeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeBackgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.83, alpha: 1)
        tv.processDelegate = self   // get notified when the process exits (you type `exit`, Claude quits)

        let spec = launchSpec(for: tab, cwd: cwd)
        tv.startProcess(executable: spec.exe, args: spec.args, environment: spec.env,
                        execName: nil, currentDirectory: cwd)
        views[tab.id] = tv
        return tv
    }


    // MARK: Command terminals (one-shot docker actions, watchable + promotable to a tab)

    /// Reserved id prefix for action PTYs (a `docker compose up/down/...` run shown in the peek overlay).
    static let commandPrefix = "__cmd__"
    /// Fires when a command PTY's process exits, with its exit code — drives auto-show-on-failure.
    var onCommandExit: ((_ id: String, _ code: Int32?) -> Void)?

    /// Spawn a PTY that runs a one-shot command (a docker compose action), keyed by `id`. Reuses a live
    /// view for the same id. Tab-terminal tint so it looks right when promoted to a tab.
    func commandView(id: String, exe: String, args: [String], cwd: String) -> MulteeTerminalView {
        installScrollMonitorIfNeeded()
        if let v = views[id] { return v }
        let tv = MulteeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeBackgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.83, alpha: 1)
        tv.processDelegate = self
        tv.startProcess(executable: exe, args: args, environment: Env.array(), execName: nil, currentDirectory: cwd)
        views[id] = tv
        return tv
    }

    /// Promote a command PTY into a tab (re-key its live view; output + scrollback survive). The caller
    /// adds a `.terminal` Tab with `tabID`, which `CenterViewController` renders by reusing this view.
    func promoteCommand(commandID: String, tabID: String) {
        guard let v = views[commandID] else { return }
        views[commandID] = nil
        v.removeFromSuperview()
        views[tabID] = v
    }

    // MARK: Quick terminals (one or more per session, never tabs)

    /// Reserved id prefix for a session's quick-access terminals (the ⌃` shells). Distinct from any tab
    /// id so they live alongside the session's tab PTYs without colliding. A session can hold several;
    /// each id is `__quick__<sessionID>::<n>`. `QuickTerminalController` owns the per-session list +
    /// active selection; this store just owns the PTYs.
    static let quickPrefix = "__quick__"
    private static let quickSep = "::"

    private var quickCounters: [String: Int] = [:]   // sessionID → next suffix (monotonic, never reused)

    /// Spawn a brand-new quick shell for a session (opened in its repo root); returns its id + view.
    /// A plain interactive login shell — no Claude, no hooks; just a scratch terminal you pop with ⌃`.
    func newQuickView(sessionID: String, cwd: String) -> (id: String, view: MulteeTerminalView) {
        let n = (quickCounters[sessionID] ?? 0) + 1
        quickCounters[sessionID] = n
        let id = "\(Self.quickPrefix)\(sessionID)\(Self.quickSep)\(n)"
        return (id, spawnQuick(id: id, cwd: cwd))
    }

    /// Get (or lazily re-spawn) a quick shell by its explicit id.
    func quickView(id: String, cwd: String) -> MulteeTerminalView {
        if let v = views[id] { return v }
        return spawnQuick(id: id, cwd: cwd)
    }

    private func spawnQuick(id: String, cwd: String) -> MulteeTerminalView {
        installScrollMonitorIfNeeded()
        let tv = MulteeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeBackgroundColor = QuickTerminalController.backgroundColor   // distinct tint vs tab terminals
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.83, alpha: 1)
        tv.processDelegate = self
        let exe = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        tv.startProcess(executable: exe, args: ["-l"], environment: Env.array(),
                        execName: nil, currentDirectory: cwd)
        views[id] = tv
        return tv
    }

    /// Kill every quick shell a session owns (called from `Session.killTerminals`).
    func closeAllQuick(sessionID: String) {
        let prefix = "\(Self.quickPrefix)\(sessionID)\(Self.quickSep)"
        for id in views.keys where id.hasPrefix(prefix) { close(id) }
        quickCounters[sessionID] = nil
    }

    /// Promote a quick shell into a tab: re-key its live PTY under the new tab id (running process +
    /// scrollback survive) and restyle to the tab-terminal tint. The caller then adds a `.terminal` Tab
    /// with `tabID`, which `CenterViewController` renders by reusing this view instead of spawning fresh.
    func promoteQuick(quickID: String, tabID: String) {
        guard let v = views[quickID] else { return }
        views[quickID] = nil
        v.removeFromSuperview()
        v.nativeBackgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1)   // match tab terminals
        views[tabID] = v
    }

    func has(_ id: String) -> Bool { views[id] != nil }

    func close(_ id: String) {
        views[id]?.terminate()
        views[id]?.removeFromSuperview()
        views[id] = nil
    }

    func focus(_ id: String) {
        guard let v = views[id] else { return }
        v.window?.makeFirstResponder(v)
    }

    func send(_ id: String, _ txt: String) { views[id]?.send(txt: txt) }

    /// The terminal's visible grid as text (production read — Quick Ask uses it to spot Claude's
    /// large-session "Resume from summary / full" menu and auto-pick "full").
    func screenText(_ id: String) -> String? { debugText(id) }

    // MARK: Debug harness (DEV only)

    func debugScroll(_ id: String, up: Bool, lines: Int) {
        views[id]?.debugScroll(up: up, lines: lines)
    }

    /// The terminal's visible grid as text (rtrimmed, trailing blank lines dropped). Lets the
    /// harness assert on actual rendered output instead of relying on the self-screenshot, which
    /// can't capture SwiftTerm's CoreText drawing.
    func debugText(_ id: String) -> String? {
        guard let v = views[id], let t = v.terminal else { return nil }
        var lines: [String] = []
        for r in 0..<t.rows {
            var line = ""
            for c in 0..<t.cols {
                let ch = t.getCharacter(col: c, row: r) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            lines.append(String(line.reversed().drop(while: { $0 == " " }).reversed()))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func debugState(_ id: String) -> [String: Any]? {
        guard let v = views[id], let t = v.terminal else { return nil }
        return [
            "isAlternateBuffer": t.isCurrentBufferAlternate,
            "mouseMode": String(describing: t.mouseMode),
            "scrollPosition": v.scrollPosition,
            "canScroll": v.canScroll,
            "rows": t.rows,
            "cols": t.cols,
            "repaints": v.repaintCount,
        ]
    }
}

// MARK: - Process termination

/// `processDelegate` for every spawned terminal. The size/title/cwd callbacks are no-ops (SwiftTerm's own
/// `TerminalView` delegate already does the load-bearing work, e.g. SIGWINCH); we only care about exit.
extension TerminalStore: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // May arrive off the main thread; do the (main-only) `views` lookup + notify on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.views.first(where: { $0.value === source })?.key else { return }
            if id.hasPrefix(Self.commandPrefix) {
                self.onCommandExit?(id, exitCode)   // action PTY → auto-show overlay on non-zero
            } else if id.hasPrefix(Self.quickPrefix) {
                self.onQuickExit?(id)   // full quick id; the controller maps it back to a session + list
            } else {
                self.onExit?(id)
            }
        }
    }
}

// MARK: - Terminal view with scroll forwarding + scrollbar cursor

/// Transparent strip drawn over the scroller. SwiftTerm blankets the whole view with an I-beam
/// cursor rect; since macOS resolves the cursor from the *hit-tested* view, we must be that view to
/// show the arrow. So this overlay sits in front of the scroller and claims hits (→ arrow cursor)
/// but forwards mouse-down to the real NSScroller, whose own drag-tracking loop then runs.
private final class ScrollerCursorOverlay: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private var scroller: NSScroller? {
        superview?.subviews.lazy.compactMap { $0 as? NSScroller }.first
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        scroller != nil ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let scroller else { return super.mouseDown(with: event) }
        scroller.mouseDown(with: event)   // runs the scroller's own modal drag-tracking loop
    }
}

/// SwiftTerm's wheel handling ignores trackpad gestures (bails on `deltaY == 0`) and never forwards
/// the wheel to alternate-buffer TUIs (like Claude). `scrollWheel` is `public override` (not `open`)
/// so we can't override it; instead `TerminalStore`'s shared monitor routes events here.
final class MulteeTerminalView: LocalProcessTerminalView {
    private var scrollAccumulator: CGFloat = 0

    /// DEV instrumentation: paint count, sampled by the state dump to detect flicker.
    private(set) var repaintCount: Int = 0
    public override func viewWillDraw() {
        repaintCount &+= 1
        super.viewWillDraw()
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        installScrollerCursorOverlay()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        installScrollerCursorOverlay()
    }

    private func installScrollerCursorOverlay() {
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let overlay = ScrollerCursorOverlay(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    /// Handle a wheel event the shared monitor routed to us. Returns true if we scrolled.
    fileprivate func handleWheel(_ event: NSEvent) -> Bool {
        guard let terminal else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY
        if delta == 0 { return false }

        let cellHeight = max(1, frame.height / CGFloat(max(1, terminal.rows)))
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? cellHeight : 1
        scrollAccumulator += delta
        let notches = Int(scrollAccumulator / threshold)
        if notches == 0 { return true }
        scrollAccumulator -= CGFloat(notches) * threshold

        let linesPerNotch = event.hasPreciseScrollingDeltas ? 1 : 3
        let lines = min(abs(notches) * linesPerNotch, 200)
        performScroll(up: notches > 0, lines: lines, at: point, flags: event.modifierFlags)
        return true
    }

    /// In the alt buffer with mouse reporting, forward SGR wheel events to the app; otherwise scroll
    /// SwiftTerm's own scrollback.
    private func performScroll(up: Bool, lines: Int, at point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let terminal, lines > 0 else { return }
        if terminal.isCurrentBufferAlternate, terminal.mouseMode != .off {
            let buttonFlags = terminal.encodeButton(button: up ? 4 : 5, release: false,
                                                    shift: flags.contains(.shift),
                                                    meta: flags.contains(.option),
                                                    control: flags.contains(.control))
            let cellW = max(1, frame.width / CGFloat(max(1, terminal.cols)))
            let cellH = max(1, frame.height / CGFloat(max(1, terminal.rows)))
            let col = min(max(0, Int(point.x / cellW)), terminal.cols - 1)
            let row = min(max(0, Int((frame.height - point.y) / cellH)), terminal.rows - 1)
            for _ in 0..<lines { terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row) }
        } else {
            if up { scrollUp(lines: lines) } else { scrollDown(lines: lines) }
        }
    }

    /// DEV harness entry point: scroll without a real wheel event.
    func debugScroll(up: Bool, lines: Int) {
        performScroll(up: up, lines: lines, at: CGPoint(x: bounds.midX, y: bounds.midY), flags: [])
    }
}
