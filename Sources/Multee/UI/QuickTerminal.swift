import AppKit
import Combine

/// Lets the ⌃` menu item / key monitor reach the single quick-terminal controller owned by the window
/// controller — same static-hook pattern as `CommandPaletteHook` / `SidebarSearchHook`.
enum QuickTerminalHook {
    static var toggle: (() -> Void)?
}

/// A quick-access terminal (VS Code's ⌃`): per-session login shells you pop open and dismiss with the
/// same shortcut. A session can hold **several** shells (a chip strip in the panel header switches /
/// adds / closes them), each a PTY owned by `TerminalStore` under a reserved id (`__quick__<sid>::<n>`,
/// never a tab). The panel can appear three ways (Settings → "Quick terminal opens as"): a **floating
/// window**, a **centered overlay**, or a **bottom panel**. The controller owns one chrome view
/// (`QuickTerminalPanel`: header + content) and re-parents *it* between the three containers; the active
/// shell lives inside the chrome's content, so switching mode/session/shell never restarts a process.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    static weak var current: QuickTerminalController?

    /// A deep, dark background so it reads as a real terminal (high contrast), and is differentiated from the
    /// surroundings by being the *darkest* surface (content ~0.11, tab terminals ~0.118). Shared by the shell's
    /// own fill, its container, and the bottom dock.
    static let backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
    /// Breathing room between the terminal and its container edge, in all three modes.
    static let padding: CGFloat = 8

    /// One session's quick shells: the ordered TerminalStore ids + which one is on screen.
    private struct QuickList { var ids: [String]; var activeID: String }
    private var lists: [String: QuickList] = [:]   // sessionID → its quick shells (ephemeral, not persisted)

    private let model: AppModel
    private weak var root: NSView?                 // main window root, for the centered overlay
    private var cancellables = Set<AnyCancellable>()

    private(set) var isShown = false
    private var shownMode: Settings.QuickTermMode?
    private var mountConstraints: [NSLayoutConstraint] = []

    /// The single chrome (header chip-strip + terminal content) shared across all three modes; only this
    /// re-parents between containers.
    private let chrome = QuickTerminalPanel()

    // Floating-window presenter.
    private var floatingPanel: QuickTermPanel?
    private var floatingHost: NSView?
    // Centered-overlay presenter (in-window).
    private var scrim: QuickTermScrim?
    private let overlayBox = NSView()

    init(model: AppModel) {
        self.model = model
        super.init()
        QuickTerminalController.current = self
        chrome.onSelect     = { [weak self] id in self?.selectTerminal(id) }
        chrome.onNew        = { [weak self] in self?.addTerminal() }
        chrome.onClose      = { [weak self] id in self?.closeTerminal(id) }
        chrome.onOpenAsTab  = { [weak self] in self?.openActiveAsTab() }
        // Re-target on session switch and re-present on a mode change — but only while shown.
        model.$activeSessionID
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.activeSessionChanged() }
            .store(in: &cancellables)
        model.settings.$quickTermMode
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.modeChanged() }
            .store(in: &cancellables)
        // Drop a closed session's shell list (its PTYs are killed in `Session.killTerminals`, but that
        // path doesn't fire `onQuickExit`, so prune here to avoid stale entries).
        model.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let live = Set(sessions.map { $0.id })
                self.lists.keys.filter { !live.contains($0) }.forEach { self.lists[$0] = nil }
            }
            .store(in: &cancellables)
    }

    func attach(root: NSView) { self.root = root }

    // MARK: - Toggle

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard model.activeSession != nil else { return }   // no repo open → nothing to run in
        ensureList()
        present(mode: model.settings.quickTermMode)
        syncChrome()
        isShown = true
    }

    func hide() {
        teardownFloating(); teardownCentered(); teardownBottom()
        isShown = false
        shownMode = nil
        root?.window?.makeKeyAndOrderFront(nil)        // return focus to the main window…
        CenterViewController.current?.focusActiveContent()   // …and into your session/file
    }

    private func activeSessionChanged() {
        guard isShown else { return }
        guard model.activeSession != nil else { hide(); return }   // last session closed → hide
        ensureList()
        syncChrome()
    }

    private func modeChanged() {
        guard isShown, model.activeSession != nil else { return }
        present(mode: model.settings.quickTermMode)
        syncChrome()
    }

    // MARK: - Per-session shell list

    /// Make sure the active session has at least one quick shell (lazily spawning the first).
    private func ensureList() {
        guard let s = model.activeSession else { return }
        if lists[s.id] == nil || lists[s.id]!.ids.isEmpty {
            let made = TerminalStore.shared.newQuickView(sessionID: s.id, cwd: s.url)
            lists[s.id] = QuickList(ids: [made.id], activeID: made.id)
        }
    }

    /// Push the active session's chips + active shell into the chrome and focus it.
    private func syncChrome() {
        guard let s = model.activeSession, let list = lists[s.id] else { return }
        let view = TerminalStore.shared.quickView(id: list.activeID, cwd: s.url)
        chrome.renderChips(ids: list.ids, activeID: list.activeID)
        chrome.showTerminal(view)
        focusActiveTerminal()
    }

    private func addTerminal() {
        guard let s = model.activeSession else { return }
        let made = TerminalStore.shared.newQuickView(sessionID: s.id, cwd: s.url)
        if lists[s.id] == nil {
            lists[s.id] = QuickList(ids: [made.id], activeID: made.id)
        } else {
            lists[s.id]!.ids.append(made.id)
            lists[s.id]!.activeID = made.id
        }
        syncChrome()
    }

    private func selectTerminal(_ id: String) {
        guard let s = model.activeSession, lists[s.id] != nil else { return }
        lists[s.id]!.activeID = id
        syncChrome()
    }

    private func closeTerminal(_ id: String) {
        guard let s = model.activeSession, var list = lists[s.id] else { return }
        TerminalStore.shared.close(id)
        list.ids.removeAll { $0 == id }
        if list.ids.isEmpty { lists[s.id] = nil; hide(); return }   // closed the last → dismiss
        if list.activeID == id { list.activeID = list.ids.last! }
        lists[s.id] = list
        syncChrome()
    }

    /// Promote the active shell into a real workspace tab — the running process + scrollback move with it
    /// (`TerminalStore.promoteQuick` re-keys the live PTY). The session's new `.terminal` tab reuses that
    /// view; the shell drops out of the quick list.
    private func openActiveAsTab() {
        guard let s = model.activeSession, var list = lists[s.id] else { return }
        let quickID = list.activeID
        let tab = Tab(kind: .terminal, title: "Terminal")
        TerminalStore.shared.promoteQuick(quickID: quickID, tabID: tab.id)
        list.ids.removeAll { $0 == quickID }
        if list.ids.isEmpty {
            lists[s.id] = nil
        } else {
            if list.activeID == quickID { list.activeID = list.ids.last! }
            lists[s.id] = list
        }
        s.addTab(tab)   // becomes the active tab → CenterViewController renders it by reusing the moved view
        if lists[s.id] == nil { hide() } else { syncChrome() }
    }

    /// A quick shell ended (you typed `exit`) — `onQuickExit` hands us the full id. Drop it from its
    /// session's list; if it was the on-screen one, switch to a neighbor or dismiss.
    func handleShellExit(quickID: String) {
        TerminalStore.shared.close(quickID)
        for (sid, listValue) in lists {
            var list = listValue
            guard list.ids.contains(quickID) else { continue }
            let isActiveSession = model.activeSessionID == sid
            let wasActiveTerm = list.activeID == quickID
            list.ids.removeAll { $0 == quickID }
            if list.ids.isEmpty {
                lists[sid] = nil
                if isShown && isActiveSession { hide() }
            } else {
                if wasActiveTerm { list.activeID = list.ids.last! }
                lists[sid] = list
                if isShown && isActiveSession { syncChrome() }
            }
            return
        }
    }

    private func focusActiveTerminal() {
        guard let v = chrome.terminalView else { return }
        v.window?.makeFirstResponder(v)
    }

    // MARK: - Present

    private func present(mode: Settings.QuickTermMode) {
        if mode != .floating { teardownFloating() }
        if mode != .centered { teardownCentered() }
        if mode != .bottom   { teardownBottom() }
        switch mode {
        case .floating: presentFloating()
        case .centered: presentCentered()
        case .bottom:   presentBottom()
        }
        shownMode = mode
    }

    /// Re-parent the chrome into `container`, pinned to its edges (deactivating any prior pin so it
    /// detaches cleanly from whatever container it was in).
    private func mountChrome(in container: NSView) {
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints = []
        chrome.removeFromSuperview()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chrome)
        mountConstraints = [
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
        NSLayoutConstraint.activate(mountConstraints)
    }

    // Floating window
    private func presentFloating() {
        let host = ensurePanel()
        mountChrome(in: host)
        floatingPanel?.makeKeyAndOrderFront(nil)
    }
    private func ensurePanel() -> NSView {
        if let host = floatingHost { return host }
        let p = QuickTermPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                               styleMask: [.titled, .closable, .resizable, .utilityWindow],
                               backing: .buffered, defer: false)
        p.title = "Terminal"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setFrameAutosaveName("MulteeQuickTerminal")
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = Self.backgroundColor.cgColor
        p.contentView = host
        if p.frame.origin == .zero { p.center() }
        floatingPanel = p; floatingHost = host
        return host
    }
    private func teardownFloating() { floatingPanel?.orderOut(nil) }

    // Centered overlay (in-window)
    private func presentCentered() {
        guard let root else { return }
        let scrim = ensureScrim()
        if scrim.superview == nil {
            scrim.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: root.topAnchor),
                scrim.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                scrim.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        mountChrome(in: overlayBox)
    }
    private func ensureScrim() -> QuickTermScrim {
        if let s = scrim { return s }
        let s = QuickTermScrim()
        s.wantsLayer = true
        s.layer?.backgroundColor = NSColor(white: 0, alpha: 0.38).cgColor
        s.onClickOutside = { [weak self] pt in
            guard let self else { return }
            if !self.overlayBox.frame.contains(pt) { self.hide() }
        }
        overlayBox.translatesAutoresizingMaskIntoConstraints = false
        overlayBox.wantsLayer = true
        overlayBox.layer?.backgroundColor = Self.backgroundColor.cgColor
        overlayBox.layer?.cornerRadius = 10
        overlayBox.layer?.masksToBounds = true   // clips the chrome's header corners to the rounded box
        overlayBox.layer?.borderWidth = 1
        overlayBox.layer?.borderColor = NSColor(white: 0.30, alpha: 1).cgColor
        s.addSubview(overlayBox)
        NSLayoutConstraint.activate([
            overlayBox.centerXAnchor.constraint(equalTo: s.centerXAnchor),
            overlayBox.centerYAnchor.constraint(equalTo: s.centerYAnchor),
            overlayBox.widthAnchor.constraint(equalTo: s.widthAnchor, multiplier: 0.7),
            overlayBox.heightAnchor.constraint(equalTo: s.heightAnchor, multiplier: 0.6),
        ])
        scrim = s
        return s
    }
    private func teardownCentered() { scrim?.removeFromSuperview() }

    // Bottom dock
    private func presentBottom() {
        guard let container = CenterViewController.current?.showBottomDock() else { return }
        mountChrome(in: container)
    }
    private func teardownBottom() { CenterViewController.current?.hideBottomDock() }

    // MARK: - NSWindowDelegate (floating panel close button → just hide, keep the PTYs alive)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: - Debug
    func debugState() -> [String: Any] {
        var d: [String: Any] = ["shown": isShown, "mode": shownMode.map { "\($0)" } ?? "none"]
        if let s = model.activeSession, let list = lists[s.id] {
            d["count"] = list.ids.count
            d["activeIndex"] = (list.ids.firstIndex(of: list.activeID) ?? -1) + 1   // 1-based; 0 = none
            d["text"] = TerminalStore.shared.debugText(list.activeID) ?? ""
        } else {
            d["count"] = 0
            d["text"] = ""
        }
        return d
    }
    /// The on-screen shell's id, so the harness `quickSend` can target it.
    var debugActiveID: String? {
        guard let s = model.activeSession, let list = lists[s.id] else { return nil }
        return list.activeID
    }
    func debugNewTerminal() { addTerminal() }
    func debugSelect(_ index: Int) {
        guard let s = model.activeSession, let list = lists[s.id], list.ids.indices.contains(index) else { return }
        selectTerminal(list.ids[index])
    }
    func debugClose(_ index: Int) {
        guard let s = model.activeSession, let list = lists[s.id], list.ids.indices.contains(index) else { return }
        closeTerminal(list.ids[index])
    }
    func debugOpenAsTab() { openActiveAsTab() }
}

/// The chrome shared by all three quick-terminal modes: a header strip (a chip per shell + new / open-as-tab
/// buttons + a "⌃` to hide" hint) above the active terminal. The controller mounts this whole view into the
/// floating window / centered box / bottom dock, and swaps which terminal view sits in the content area.
final class QuickTerminalPanel: NSView {
    var onSelect: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onClose: ((String) -> Void)?
    var onOpenAsTab: (() -> Void)?

    private let chipsStack = NSStackView()
    private let contentBox = NSView()
    private(set) var terminalView: NSView?
    private var contentConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = QuickTerminalController.backgroundColor.cgColor

        // Header (toolbar) strip.
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 4
        chipsStack.alignment = .centerY
        chipsStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let newBtn = iconButton("plus", "New terminal", #selector(newTapped))
        let openTabBtn = iconButton("arrow.up.right.square", "Open as tab", #selector(openAsTabTapped))

        let hint = makeHint()

        let outer = NSStackView(views: [chipsStack, newBtn, NSView(), openTabBtn, hint])
        outer.orientation = .horizontal
        outer.spacing = 8
        outer.alignment = .centerY
        outer.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(outer)

        // Divider under the header.
        let div = NSView()
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        div.translatesAutoresizingMaskIntoConstraints = false

        contentBox.wantsLayer = true
        contentBox.layer?.backgroundColor = QuickTerminalController.backgroundColor.cgColor
        contentBox.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(div)
        addSubview(contentBox)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            outer.topAnchor.constraint(equalTo: header.topAnchor),
            outer.bottomAnchor.constraint(equalTo: header.bottomAnchor),

            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            div.topAnchor.constraint(equalTo: header.bottomAnchor),
            div.leadingAnchor.constraint(equalTo: leadingAnchor),
            div.trailingAnchor.constraint(equalTo: trailingAnchor),
            div.heightAnchor.constraint(equalToConstant: 1),

            contentBox.topAnchor.constraint(equalTo: div.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild the chip strip for the current session's shells (numbered by position).
    func renderChips(ids: [String], activeID: String) {
        chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, id) in ids.enumerated() {
            let chip = QuickTermChip(
                id: id, number: i + 1, isActive: id == activeID,
                onSelect: { [weak self] in self?.onSelect?(id) },
                onClose: { [weak self] in self?.onClose?(id) })
            chipsStack.addArrangedSubview(chip)
        }
    }

    /// Put `view` (a terminal) into the content area, padded; removes whatever was there.
    func showTerminal(_ view: NSView) {
        if terminalView === view { return }
        terminalView?.removeFromSuperview()
        NSLayoutConstraint.deactivate(contentConstraints)
        view.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(view)
        let pad = QuickTerminalController.padding
        contentConstraints = [
            view.topAnchor.constraint(equalTo: contentBox.topAnchor, constant: pad),
            view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: -pad),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor, constant: pad),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor, constant: -pad),
        ]
        NSLayoutConstraint.activate(contentConstraints)
        terminalView = view
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> PointerButton {
        let b = PointerButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = NSColor(white: 0.72, alpha: 1)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// "⌃` to hide" — a keycap chip plus a muted label, so users learn the shortcut also dismisses.
    private func makeHint() -> NSView {
        let cap = NSTextField(labelWithString: "⌃`")
        cap.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        cap.textColor = NSColor(white: 0.85, alpha: 1)
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false
        let capBox = NSView()
        capBox.wantsLayer = true
        capBox.layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
        capBox.layer?.cornerRadius = 4
        capBox.layer?.borderWidth = 1
        capBox.layer?.borderColor = NSColor(white: 0.34, alpha: 1).cgColor
        capBox.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: capBox.leadingAnchor, constant: 5),
            cap.trailingAnchor.constraint(equalTo: capBox.trailingAnchor, constant: -5),
            cap.topAnchor.constraint(equalTo: capBox.topAnchor, constant: 1),
            cap.bottomAnchor.constraint(equalTo: capBox.bottomAnchor, constant: -1),
        ])
        let label = NSTextField(labelWithString: "to hide")
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.55, alpha: 1)
        let stack = NSStackView(views: [capBox, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.toolTip = "Press ⌃` to hide the terminal (and again to reopen it)"
        return stack
    }

    @objc private func newTapped() { onNew?() }
    @objc private func openAsTabTapped() { onOpenAsTab?() }
}

/// One chip in the quick-terminal header: a numbered shell with a close button. Click selects; ✕ closes.
final class QuickTermChip: PointerView {
    let id: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let closeButton = PointerButton()

    init(id: String, number: Int, isActive: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.id = id
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (isActive ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 1, alpha: 0.04)).cgColor
        toolTip = "Terminal \(number)"

        let glyph = NSTextField(labelWithString: "❯")
        glyph.font = .systemFont(ofSize: 10)
        glyph.textColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "\(number)")
        label.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor

        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 9)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close terminal"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [glyph, label, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Route clicks to the chip (select) except over the close button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? closeButton : self
    }
    override func mouseDown(with event: NSEvent) { /* claim the event so mouseUp lands here */ }
    override func mouseUp(with event: NSEvent) { onSelect() }
    @objc private func closeTapped() { onClose() }
}

/// Borderless floating panel that can take key focus (so you can type in the terminal).
private final class QuickTermPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Full-host click catcher behind the centered overlay: a click outside the box dismisses.
private final class QuickTermScrim: NSView {
    var onClickOutside: ((NSPoint) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClickOutside?(convert(event.locationInWindow, from: nil))
    }
}
