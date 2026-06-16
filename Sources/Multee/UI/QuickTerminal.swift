import AppKit
import Combine

/// Lets the ⌃` menu item / key monitor reach the single quick-terminal controller owned by the window
/// controller — same static-hook pattern as `CommandPaletteHook` / `SidebarSearchHook`.
enum QuickTerminalHook {
    static var toggle: (() -> Void)?
}

/// A quick-access terminal (VS Code's ⌃`): a per-session login shell you pop open and dismiss with the
/// same shortcut. It can appear three ways (Settings → "Quick terminal opens as"): a **floating window**,
/// a **centered overlay** inside the main window, or a **bottom panel** docked under the editor. The shell
/// is one PTY per session (cwd = its repo), owned by `TerminalStore`; this controller only moves that one
/// terminal view between the three containers — so switching mode or session never restarts the shell.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    static weak var current: QuickTerminalController?

    /// A deep, dark background so it reads as a real terminal (high contrast), and is differentiated from the
    /// surroundings by being the *darkest* surface (content ~0.11, tab terminals ~0.118). Shared by the shell's
    /// own fill, its container, and the bottom dock.
    static let backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
    /// Breathing room between the terminal and its container edge, in all three modes.
    static let padding: CGFloat = 8

    private let model: AppModel
    private weak var root: NSView?                 // main window root, for the centered overlay
    private var cancellables = Set<AnyCancellable>()

    private(set) var isShown = false
    private var shownMode: Settings.QuickTermMode?
    private var mountConstraints: [NSLayoutConstraint] = []
    private weak var mountedView: NSView?   // the terminal currently in a container (differs across sessions)

    // Floating-window presenter.
    private var panel: QuickTermPanel?
    private var panelHost: NSView?
    // Centered-overlay presenter (in-window).
    private var scrim: QuickTermScrim?
    private let overlayBox = NSView()

    init(model: AppModel) {
        self.model = model
        super.init()
        QuickTerminalController.current = self
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
    }

    func attach(root: NSView) { self.root = root }

    // MARK: - Toggle

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard let view = resolveView() else { return }   // no repo open → nothing to run in
        present(view, mode: model.settings.quickTermMode)
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
        guard let view = resolveView() else { hide(); return }   // last session closed → hide
        present(view, mode: shownMode ?? model.settings.quickTermMode)
    }

    private func modeChanged() {
        guard isShown, let view = resolveView() else { return }
        present(view, mode: model.settings.quickTermMode)
    }

    /// The active session's quick shell (spawns lazily). Nil when no repo is open.
    private func resolveView() -> MulteeTerminalView? {
        guard let s = model.activeSession else { return nil }
        return TerminalStore.shared.quickView(sessionID: s.id, cwd: s.url)
    }

    // MARK: - Present

    private func present(_ view: MulteeTerminalView, mode: Settings.QuickTermMode) {
        if mode != .floating { teardownFloating() }
        if mode != .centered { teardownCentered() }
        if mode != .bottom   { teardownBottom() }
        switch mode {
        case .floating: presentFloating(view)
        case .centered: presentCentered(view)
        case .bottom:   presentBottom(view)
        }
        shownMode = mode
    }

    /// Move the one terminal view into `container`, pinned to its edges (deactivating any prior pin so the
    /// view detaches cleanly from whatever container it was in).
    private func mount(_ view: NSView, in container: NSView) {
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints = []
        if let old = mountedView, old !== view { old.removeFromSuperview() }   // drop the prior session's view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        mountedView = view
        let pad = Self.padding
        mountConstraints = [
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
        ]
        NSLayoutConstraint.activate(mountConstraints)
    }

    // Floating window
    private func presentFloating(_ view: MulteeTerminalView) {
        let host = ensurePanel()
        mount(view, in: host)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(view)
    }
    private func ensurePanel() -> NSView {
        if let host = panelHost { return host }
        let p = QuickTermPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
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
        panel = p; panelHost = host
        return host
    }
    private func teardownFloating() { panel?.orderOut(nil) }

    // Centered overlay (in-window)
    private func presentCentered(_ view: MulteeTerminalView) {
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
        mount(view, in: overlayBox)
        root.window?.makeFirstResponder(view)
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
        overlayBox.layer?.masksToBounds = true
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
    private func presentBottom(_ view: MulteeTerminalView) {
        guard let container = CenterViewController.current?.showBottomDock() else { return }
        mount(view, in: container)
        container.window?.makeFirstResponder(view)
    }
    private func teardownBottom() { CenterViewController.current?.hideBottomDock() }

    // MARK: - NSWindowDelegate (floating panel close button → just hide, keep the PTY alive)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: - Debug
    func debugState() -> [String: Any] {
        ["shown": isShown,
         "mode": shownMode.map { "\($0)" } ?? "none",
         "text": (model.activeSessionID.flatMap { TerminalStore.shared.debugQuickText($0) }) ?? ""]
    }
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
