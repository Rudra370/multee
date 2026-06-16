import AppKit
import Combine

/// Persistent menu-bar (system status bar) indicator of session attention — complements the transient
/// notification banners and the in-app SESSIONS dots by being glanceable while Multee is in the background.
/// The icon tints by the aggregate state across all sessions (orange = a session needs you, blue = working,
/// else idle) and shows a **count** of how many need you; the dropdown lists each session with its Claude
/// tabs, and selecting one brings Multee forward and jumps to it. Event-driven off the same status the hooks
/// already produce — no polling.
final class AttentionItem: NSObject, NSMenuDelegate {
    static weak var current: AttentionItem?   // for the debug harness (the menu bar is outside the window)

    private let model: AppModel
    /// Bring Multee forward + switch to (session, tab?). Supplied by AppDelegate so the window logic lives there.
    var onJump: ((_ sessionID: String, _ tabID: String?) -> Void)?

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var sessionObservers: [String: AnyCancellable] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        AttentionItem.current = self
    }

    /// Begin observing: the setting toggles the item in/out; model + per-session status drive the icon.
    func start() {
        model.settings.$showMenuBarStatus
            .sink { [weak self] on in on ? self?.install() : self?.remove() }
            .store(in: &cancellables)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.observeSessions(); self?.refresh() }
            .store(in: &cancellables)
        observeSessions()
    }

    // MARK: - Status item lifecycle

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading      // the image (set in refresh) leads the count
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.toolTip = "Claude sessions"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refresh()
    }

    private func remove() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    /// Re-subscribe to each session's `objectWillChange` (its `tabStatus` mutations fire there, not on the
    /// model) so the icon updates the moment a hook flips a tab's status — same pattern as the sidebar.
    private func observeSessions() {
        sessionObservers = Dictionary(uniqueKeysWithValues: model.sessions.map { session in
            (session.id, session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.refresh() })
        })
    }

    // MARK: - Icon

    /// Multee's `»` mark in `color`, or an adaptive template (idle) when `color` is nil. Drawn as a single-color
    /// silhouette (rounded caps, matching the logo) so it tints cleanly to blue/orange — the full two-tone logo
    /// can't be recolored, and a template + `contentTintColor` renders monochrome in the menu bar regardless.
    private static func symbol(_ color: NSColor?) -> NSImage {
        let dev = Bundle.main.isDev
        let size = NSSize(width: 15, height: 13)
        let img = NSImage(size: size, flipped: false) { rect in
            let ink = color ?? .black            // template (nil) ignores RGB, uses alpha; opaque is all that matters
            ink.setStroke()
            let top = rect.maxY - 1.5, bot = rect.minY + 1.5, mid = rect.midY
            let cw: CGFloat = 4.3                 // each chevron's horizontal reach
            for x in [rect.minX + 2.2, rect.minX + 6.7] {
                let p = NSBezierPath()
                p.lineWidth = 2.1
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.move(to: NSPoint(x: x, y: top))
                p.line(to: NSPoint(x: x + cw, y: mid))
                p.line(to: NSPoint(x: x, y: bot))
                p.stroke()
            }
            // Dev build: a small dot in the top-right negative space — distinguishes dev vs prod at a glance
            // without widening the icon. It tints with the status color, so it's a shape marker, not a signal.
            if dev {
                ink.setFill()
                let r: CGFloat = 1.4
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 1.9 - r, y: rect.maxY - 2.2 - r, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        img.isTemplate = (color == nil)          // idle → adapts to the menu bar
        return img
    }

    private static func isAttention(_ s: ClaudeState) -> Bool { s == .needs || s == .done }

    /// Number of sessions currently needing you — permission prompts *or* finished-and-waiting.
    private var needsCount: Int { model.sessions.filter { Self.isAttention($0.status) }.count }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let needs = needsCount
        if needs > 0 {
            button.image = Self.symbol(.systemOrange)
            button.title = " \(needs)"
        } else if model.sessions.contains(where: { $0.status == .working }) {
            button.image = Self.symbol(.systemBlue)
            button.title = ""
        } else {
            button.image = Self.symbol(nil)      // idle → adaptive template
            button.title = ""
        }
    }

    // MARK: - Menu (rebuilt each open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header — a live summary, colored by urgency.
        let (summary, sumColor) = headerSummary()
        addItemView(AttentionHeaderView(summary: summary, color: sumColor), to: menu)

        if !model.sessions.isEmpty {
            menu.addItem(.separator())
            // Needs-you first, then working, then idle — the actionable sessions sit at the top.
            let ordered = model.sessions.enumerated().sorted {
                Self.rank($0.element.status) != Self.rank($1.element.status)
                    ? Self.rank($0.element.status) < Self.rank($1.element.status)
                    : $0.offset < $1.offset
            }.map(\.element)

            for session in ordered {
                let sid = session.id
                addItemView(AttentionRowView(title: session.name, status: session.status, indent: 0, bold: true) {
                    [weak self] in self?.onJump?(sid, nil)
                }, to: menu)

                // Detail rows only when a session runs more than one Claude tab (else the row says it all).
                let claudeTabs = session.tabs.filter { $0.kind == .claude }
                if claudeTabs.count > 1 {
                    for tab in claudeTabs {
                        let st = session.tabStatus[tab.id] ?? .idle
                        let tid = tab.id
                        addItemView(AttentionRowView(title: tab.title, status: st, indent: 18, bold: false) {
                            [weak self] in self?.onJump?(sid, tid)
                        }, to: menu)
                    }
                }
            }
        }

        menu.addItem(.separator())
        addAction(menu, "Settings…", "gearshape", #selector(openSettingsAction))
        addAction(menu, "Open Multee", "macwindow", #selector(activateApp))
    }

    private func addItemView(_ view: NSView, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ symbol: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        menu.addItem(item)
    }

    private func headerSummary() -> (String, NSColor) {
        let need = needsCount
        if need > 0 { return (need == 1 ? "1 session needs you" : "\(need) sessions need you", .systemOrange) }
        let working = model.sessions.filter { $0.status == .working }.count
        if working > 0 { return (working == 1 ? "1 session working" : "\(working) sessions working", .systemBlue) }
        if model.sessions.isEmpty { return ("No sessions open", NSColor(white: 0.5, alpha: 1)) }
        return ("All caught up", NSColor(white: 0.5, alpha: 1))
    }

    @objc private func activateApp() { onJump?(model.activeSessionID ?? "", nil) }
    @objc private func openSettingsAction() { NSApp.activate(ignoringOtherApps: true); model.showSettings = true }

    private static func rank(_ s: ClaudeState) -> Int { isAttention(s) ? 0 : s == .working ? 1 : 2 }

    // MARK: - Debug harness (the menu bar is outside the app window — assert on computed state instead)

    func debugState() -> [String: Any] {
        let tint = needsCount > 0 ? "orange" : (model.sessions.contains { $0.status == .working } ? "blue" : "none")
        return ["installed": statusItem != nil,
                "needsCount": needsCount,
                "tint": tint,
                "title": statusItem?.button?.title ?? "",
                "sessions": model.sessions.map { ["name": $0.name, "status": $0.status.rawValue] }]
    }
}
