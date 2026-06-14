import AppKit
import SwiftTerm

/// One persistent PTY view per tab id — the process stays alive across tab/session switches, so
/// nothing is killed just by looking away. Keyed by the tab's `String` id.
final class TerminalStore {
    static let shared = TerminalStore()

    private var views: [String: MulteeTerminalView] = [:]
    /// Current shared font size (seeded from Settings); new terminals use it.
    var fontSize: Double = 13

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

    /// Get (or lazily spawn) the terminal view for a tab. `cwd` is the session's repo root.
    func view(for tab: Tab, cwd: String) -> MulteeTerminalView {
        installScrollMonitorIfNeeded()
        if let v = views[tab.id] { return v }

        let tv = MulteeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeBackgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.83, alpha: 1)

        let exe: String
        let args: [String]
        var extraEnv: [String: String] = [:]
        switch tab.kind {
        case .claude:
            exe = Env.resolve("claude")
            // Resume the saved conversation only if Claude's transcript for it still exists; else
            // start fresh (a wrong guess just means "fresh", never a dead tab).
            let userArgs = tab.args.split(separator: " ").map(String.init)
            let base: [String]
            if let cid = tab.claudeSessionId, Self.conversationExists(sessionId: cid) {
                base = userArgs.filter { $0 != "--continue" && $0 != "--resume" } + ["--resume", cid]
            } else {
                base = userArgs
            }
            args = base + ["--settings", Hooks.json]
            extraEnv["MULTEE_SESSION_ID"] = tab.id
            extraEnv["MULTEE_HOOK_PORT"] = String(HookServer.shared.port)
        case .terminal, .file, .diff:   // only .terminal reaches here (file/diff use their own views)
            exe = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // A terminal tab created with an initial command (e.g. "Install" a formatter) runs it, then
            // drops to an interactive login shell so its output stays visible.
            args = tab.args.isEmpty ? ["-l"] : ["-l", "-c", "\(tab.args); exec \(exe) -l"]
        }
        tv.startProcess(executable: exe, args: args, environment: Env.array(extra: extraEnv),
                        execName: nil, currentDirectory: cwd)
        views[tab.id] = tv
        return tv
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
