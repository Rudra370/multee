import AppKit
import Combine

/// Lets the ⌘/ menu item / key monitor reach the single Quick Ask controller.
enum QuickAskHook {
    static var toggle: (() -> Void)?
}

/// **Quick Ask** — ask the active Claude session a side question *without touching its chat history*. It
/// hosts a **real interactive** `claude --resume <cid> --fork-session` in a centered panel: forking the live
/// conversation *in interactive mode* reuses its warm prompt cache, so the first answer is as fast as the
/// ongoing chat. (A headless `claude -p` fork can't — print mode sends a different request prefix, so the
/// prompt cache misses and it cold-prefills the whole context; that was the old, slow approach — see D23/D24.)
/// A `Context | Blank` toggle picks forking the conversation vs a fresh context-free session, and **Open as
/// Tab** promotes the throwaway fork into a real Claude tab. The fork's PTY is keyed by a real tab id and
/// kept alive across hide, so reopening continues the thread and promotion is just `addTab` (the live PTY +
/// warm conversation carry over, and hooks/restart then behave like any forked Claude tab).
final class QuickAskController: NSObject {
    static weak var current: QuickAskController?

    private let model: AppModel
    private weak var root: NSView?
    private(set) var isShown = false

    // Centered overlay (in-window): a dimming scrim with a rounded box holding the panel.
    private var scrim: QuickAskScrim?
    private let box = NSView()
    private let panel = QuickAskPanel()

    // The source conversation (the active Claude tab) captured when a fresh thread opens.
    private var sourceCid: String?
    private var sourceCwd: String?
    private var useContext = true

    // The live throwaway fork shown in the panel: a `.claude` tab kept OUT of the session until "Open as
    // Tab". Its id keys the PTY in TerminalStore, so promotion just adds this tab.
    private var askTab: Tab?

    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        QuickAskController.current = self
        panel.onClose = { [weak self] in self?.hide() }
        panel.onNew = { [weak self] in self?.newThread() }
        panel.onOpenAsTab = { [weak self] in self?.openAsTab() }
        panel.onMode = { [weak self] ctx in self?.setMode(context: ctx) }
        // The fork belongs to whatever chat is active; if the user switches sessions, drop the stale fork so
        // the next open re-forks the new active chat.
        cancellable = model.$activeSessionID.dropFirst().sink { [weak self] _ in self?.onSessionSwitch() }
    }

    func attach(root: NSView) { self.root = root }

    // MARK: - Toggle / present

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard let root else { return }
        if askTab == nil { captureSource() }   // fresh; an in-progress thread keeps its source
        ensureSession()
        presentCentered(in: root)
        if let scrim { Motion.presentOverlay(scrim: scrim, box: box) }
        isShown = true
        focusTerminal()
    }

    func hide() {
        if let scrim, scrim.superview != nil {
            Motion.dismissOverlay(scrim: scrim, box: box) { [weak scrim] in scrim?.removeFromSuperview() }
        }
        isShown = false
        root?.window?.makeKeyAndOrderFront(nil)
        CenterViewController.current?.focusActiveContent()
    }

    private func onSessionSwitch() {
        endSession()   // the fork belonged to the previous active chat
        if isShown { captureSource(); ensureSession(); focusTerminal() }
    }

    /// Snapshot the active Claude tab as the fork source (or none → Blank-only).
    private func captureSource() {
        if let session = model.activeSession, let tab = session.activeTab,
           tab.kind == .claude, let cid = tab.claudeSessionId,
           TerminalStore.shared.canFork(sessionId: cid) {
            sourceCid = cid
            sourceCwd = session.url
            useContext = true
            panel.setSource(tab.title, canContext: true)
        } else {
            sourceCid = nil
            sourceCwd = nil
            useContext = false
            panel.setSource(nil, canContext: false)   // no forkable chat → Blank only
        }
    }

    /// Spawn the fork (or blank) PTY if there isn't one, and put it in the panel.
    private func ensureSession() {
        let cwd = sourceCwd ?? model.activeSession?.url
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let isNew = askTab == nil
        if askTab == nil {
            // forkParentId set → `--resume <cid> --fork-session` (interactive, warm cache); nil → fresh blank.
            askTab = Tab(kind: .claude, title: "Claude (fork)", forkParentId: useContext ? sourceCid : nil)
        }
        guard let tab = askTab else { return }
        panel.showTerminal(TerminalStore.shared.view(for: tab, cwd: cwd))
        if isNew, tab.forkParentId != nil { watchResume(tab.id) }   // auto-skip the large-session resume menu
    }

    // Forking a large/old chat makes Claude show a "Resume from summary / full / don't ask" menu. For Quick
    // Ask we always want the FULL session — it reuses the chat's warm prompt cache (a summary is freshly
    // generated, so it's cold *and* lossy). Watch the fork's screen briefly and auto-pick "2. Resume full
    // session as-is" by its **number** (not ↓, which Claude's input box treats as history-recall and would
    // run a stray past command). If no menu appears (small session), the watcher times out — it only sends
    // once the menu's own text is on screen.
    private var resumeAnswered = Set<String>()

    private func watchResume(_ id: String) { pollResume(id, tries: 0) }

    private func pollResume(_ id: String, tries: Int) {
        guard askTab?.id == id, !resumeAnswered.contains(id) else { return }
        if let text = TerminalStore.shared.screenText(id), text.contains("Resume full session") {
            resumeAnswered.insert(id)
            TerminalStore.shared.send(id, "2")   // digit auto-confirms the menu; NO trailing Enter (an empty
            return                               // Enter would accept Claude's ghost history suggestion and run it)
        }
        guard tries < 30 else { return }   // ~12s, then give up (user can pick manually)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollResume(id, tries: tries + 1) }
    }

    private func focusTerminal() {
        guard let id = askTab?.id else { return }
        DispatchQueue.main.async { TerminalStore.shared.focus(id) }
    }

    /// Context ↔ Blank: restart the thread in the chosen mode (a fresh fork, or a fresh blank session).
    private func setMode(context: Bool) {
        let want = context && sourceCid != nil
        guard want != useContext else { return }
        useContext = want
        endSession()
        ensureSession()
        focusTerminal()
    }

    /// "New" — drop the current fork and start a fresh one (re-reading the active chat).
    func newThread() {
        endSession()
        captureSource()
        ensureSession()
        focusTerminal()
    }

    /// Promote the live fork into a real Claude tab (the PTY + conversation carry over — it's already keyed
    /// by this tab id, so `CenterViewController` reuses it). Release our hold so closing the panel won't kill it.
    func openAsTab() {
        guard let tab = askTab, let session = model.activeSession else { return }
        _ = session.addTab(tab)
        askTab = nil   // handed off — don't kill the PTY
        hide()
    }

    /// Kill the live fork PTY and forget it.
    private func endSession() {
        if let id = askTab?.id { TerminalStore.shared.close(id); resumeAnswered.remove(id) }
        askTab = nil
    }

    // MARK: - Overlay

    private func presentCentered(in root: NSView) {
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
    }

    private func ensureScrim() -> QuickAskScrim {
        if let s = scrim { return s }
        let s = QuickAskScrim()
        s.wantsLayer = true
        s.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        s.onClickOutside = { [weak self] pt in
            guard let self else { return }
            if !self.box.frame.contains(pt) { self.hide() }
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0.30, alpha: 1).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: box.topAnchor),
            panel.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        s.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: s.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: s.centerYAnchor),
            box.widthAnchor.constraint(equalTo: s.widthAnchor, multiplier: 0.62),
            box.heightAnchor.constraint(equalTo: s.heightAnchor, multiplier: 0.66),
        ])
        scrim = s
        return s
    }

    // MARK: - Debug (dev harness)

    func debugMode(_ context: Bool) { setMode(context: context) }

    /// Send a question into the embedded terminal (with a return), to drive the fork for verification.
    func debugSend(_ text: String) {
        guard let id = askTab?.id else { return }
        TerminalStore.shared.send(id, text + "\r")
    }

    /// Dump the panel state + the launch args (proves fork/resume flags) + the terminal's rendered text.
    func debugDump() -> String {
        let id = askTab?.id ?? "<none>"
        let args = askTab.map {
            TerminalStore.shared.debugLaunchArgs(for: $0, cwd: sourceCwd ?? ".").joined(separator: " ")
        } ?? "<none>"
        let term = askTab != nil ? (TerminalStore.shared.debugText(id) ?? "<no terminal>") : "<no session>"
        return "shown=\(isShown) mode=\(useContext ? "context" : "blank") source=\(sourceCid ?? "<none>") "
            + "askTab=\(id)\nargs=\(args)\n--- terminal ---\n\(term)"
    }
}

/// The Quick Ask panel: a header (title + source + Context/Blank toggle + New / Open as Tab / close) over an
/// embedded terminal that hosts the real interactive fork.
final class QuickAskPanel: NSView {
    var onClose: (() -> Void)?
    var onNew: (() -> Void)?
    var onOpenAsTab: (() -> Void)?
    var onMode: ((Bool) -> Void)?   // true = Context

    private let sourceLabel = NSTextField(labelWithString: "")
    private let modeControl = PointerSegmentedControl()
    private let contentBox = NSView()
    private var contentConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "Quick Ask")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(white: 0.95, alpha: 1)
        title.setContentHuggingPriority(.required, for: .horizontal)

        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail

        modeControl.segmentCount = 2
        modeControl.setLabel("Context", forSegment: 0)
        modeControl.setLabel("Blank", forSegment: 1)
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: 11)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        let newButton = textButton("New", "Start a fresh Quick Ask", #selector(newTapped))
        let openTabButton = textButton("Open as Tab", "Continue this side conversation as a full Claude tab",
                                       #selector(openTapped))
        let close = iconButton("xmark", "Close (Esc closes only when the terminal isn't focused)", #selector(closeTapped))

        let header = NSStackView(views: [title, sourceLabel, NSView(), modeControl, newButton, openTabButton, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        contentBox.wantsLayer = true
        contentBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor
        contentBox.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header); addSubview(contentBox)
        let lead: CGFloat = 12, trail: CGFloat = -12
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: lead),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trail),

            contentBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            contentBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Set the source label + whether a Context fork is available; nil title → Blank only.
    func setSource(_ tabTitle: String?, canContext: Bool) {
        modeControl.setEnabled(canContext, forSegment: 0)
        modeControl.selectedSegment = canContext ? 0 : 1
        sourceLabel.stringValue = tabTitle.map { "↳ \($0)" } ?? "No forkable Claude chat — Blank only"
    }

    /// Put the embedded terminal into the content area (padded); removes whatever was there.
    func showTerminal(_ view: NSView) {
        guard view.superview !== contentBox else { return }   // already hosted (reopen) — keep as-is
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(contentConstraints)
        contentBox.addSubview(view)
        contentConstraints = [
            view.topAnchor.constraint(equalTo: contentBox.topAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor, constant: -8),
            view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(contentConstraints)
    }

    private func textButton(_ label: String, _ tip: String, _ action: Selector) -> PointerButton {
        let b = PointerButton()
        b.title = label
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> PointerButton {
        let b = PointerButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = .tertiaryLabelColor
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    @objc private func modeChanged() { onMode?(modeControl.selectedSegment == 0) }
    @objc private func newTapped() { onNew?() }
    @objc private func openTapped() { onOpenAsTab?() }
    @objc private func closeTapped() { onClose?() }
}

/// Full-host click catcher behind the centered overlay: a click outside the box dismisses.
private final class QuickAskScrim: NSView {
    var onClickOutside: ((NSPoint) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClickOutside?(convert(event.locationInWindow, from: nil))
    }
}
