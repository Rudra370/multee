import AppKit
import Combine

/// Editor → status bar nudge: the active editor calls this when its caret/selection moves, so the bar
/// refreshes Ln/Col without polling.
enum EditorStatus { static var onChange: (() -> Void)? }

/// Resource monitor → status bar: `AppDelegate`'s `ResourceMonitor` pushes mem/CPU here (only while the
/// "Show resource monitor" setting is on, which is what starts the monitor).
enum ResourceStatus { static var onUpdate: ((_ memMB: Double, _ cpu: Double) -> Void)? }

/// VS Code-style bottom status bar for the *center* pane. Left: the active session's git branch. Right
/// (editor tabs only): `Ln X, Col Y` · indentation · line-ending · language. Context-aware — the editor
/// items hide for terminal / Claude / diff / image tabs, and the whole bar hides when no repo is open.
/// Clickable: **branch** (switch / create / delete), **Ln/Col** (Go to Line), **indentation**,
/// **line-ending** (LF/CRLF), and **language**.
final class StatusBarView: NSView {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var sessionObserver: AnyCancellable?

    private let dockerButton = StatusBarView.flatButton()           // left of the branch; visible only when Docker is up
    private let branchButton = StatusBarView.flatButton()
    private let resourceLabel = NSTextField(labelWithString: "")   // mem · CPU (when enabled in settings)
    private var lastMem = 0.0, lastCpu = 0.0
    private let lnColButton = StatusBarView.flatButton()
    private let indentButton = StatusBarView.flatButton()
    private let eolButton = StatusBarView.flatButton()
    private let langButton = StatusBarView.flatButton()
    private let shortcutsButton = StatusBarView.flatButton()   // always-visible, far right
    private lazy var editorItems: [NSView] = [lnColButton, indentButton, eolButton, langButton]

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        buildUI()

        EditorStatus.onChange = { [weak self] in self?.render() }
        model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.observeActiveSession() }
            .store(in: &cancellables)
        // Track the shared font size (⌘ +/−) so the bar scales with the editor/terminal.
        model.settings.$fontSize.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateIntrinsicContentSize(); self.updateBranchIcon(); self.updateDockerIcon(); self.updateShortcutsIcon(); self.render()
            }
            .store(in: &cancellables)
        // Resource monitor: AppDelegate pushes mem/CPU here; show/hide tracks the setting.
        ResourceStatus.onUpdate = { [weak self] mem, cpu in self?.lastMem = mem; self?.lastCpu = cpu; self?.render() }
        model.settings.$showResourceMonitor.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        observeActiveSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A bit smaller than the editor body (status bars read as secondary), tracking the shared size.
    private var statusFontSize: CGFloat { max(9, CGFloat(model.settings.fontSize) - 2) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(statusFontSize) + 11)
    }

    private func observeActiveSession() {
        sessionObserver = model.activeSession?.objectWillChange
            .receive(on: RunLoop.main).sink { [weak self] in self?.render() }
        DispatchQueue.main.async { [weak self] in self?.render() }   // after CenterViewController.render set ActiveEditor.current
    }

    private func render() {
        isHidden = model.activeSession == nil

        dockerButton.isHidden = !model.dockerAvailable   // hidden entirely when the daemon isn't reachable

        let branch = model.activeSession?.gitBranch
        setTitle(branchButton, branch ?? "")
        branchButton.isHidden = branch == nil

        let showRes = model.settings.showResourceMonitor
        resourceLabel.isHidden = !showRes
        if showRes {
            resourceLabel.font = .systemFont(ofSize: statusFontSize)
            resourceLabel.textColor = StatusBarView.fg
            resourceLabel.stringValue = String(format: "%.0f MB · %.1f%% CPU", lastMem, lastCpu)
        }

        if let ed = ActiveEditor.current {
            let lc = ed.cursorLineColumn()
            setTitle(lnColButton, "Ln \(lc.line), Col \(lc.column)")
            setTitle(indentButton, ed.indentStyle)
            setTitle(eolButton, ed.lineEnding)
            setTitle(langButton, ed.languageDisplayName)
            editorItems.forEach { $0.isHidden = false }
        } else {
            editorItems.forEach { $0.isHidden = true }
        }
    }

    // MARK: - Ln/Col · EOL · indentation · language

    @objc private func goToLineClicked() { CommandPaletteHook.lineJump?() }

    @objc private func eolClicked() {
        guard let ed = ActiveEditor.current else { return }
        popUp(["LF", "CRLF"], current: ed.lineEnding, from: eolButton, action: #selector(eolPicked(_:)))
    }
    @objc private func eolPicked(_ item: NSMenuItem) {
        ActiveEditor.current?.convertLineEndings(to: item.representedObject as! String); render()
    }

    @objc private func indentClicked() {
        guard let ed = ActiveEditor.current else { return }
        popUp(["Tabs", "Spaces: 2", "Spaces: 4", "Spaces: 8"], current: ed.indentStyle,
              from: indentButton, action: #selector(indentPicked(_:)))
    }
    @objc private func indentPicked(_ item: NSMenuItem) {
        ActiveEditor.current?.convertIndentation(to: item.representedObject as! String); render()
    }

    @objc private func langClicked() {
        guard let ed = ActiveEditor.current else { return }
        let menu = NSMenu()
        let auto = menu.addItem(withTitle: "Auto-detect", action: #selector(langPicked(_:)), keyEquivalent: "")
        auto.target = self; auto.representedObject = ""    // "" = clear override
        menu.addItem(.separator())
        for lang in EditorViewController.availableLanguages() {
            let item = menu.addItem(withTitle: lang.name, action: #selector(langPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.key
            item.state = ed.languageDisplayName == lang.name ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: langButton)
    }
    @objc private func langPicked(_ item: NSMenuItem) {
        let key = item.representedObject as? String
        ActiveEditor.current?.setLanguageOverride((key?.isEmpty ?? true) ? nil : key)
        render()
    }

    /// Two-step helper for the simple LF/CRLF and indentation menus.
    private func popUp(_ options: [String], current: String, from view: NSView, action: Selector) {
        let menu = NSMenu()
        for opt in options {
            let item = menu.addItem(withTitle: opt, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = opt; item.state = opt == current ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    // MARK: - Branch (switch / create / delete)

    @objc private func branchClicked() {
        guard let repo = model.activeSession?.url else { return }
        let current = model.activeSession?.gitBranch
        let branches = Git.localBranches(repo)
        let menu = NSMenu()
        for b in branches {
            let item = menu.addItem(withTitle: b, action: b == current ? nil : #selector(checkoutBranch(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = b; item.state = b == current ? .on : .off
        }
        menu.addItem(.separator())
        let create = menu.addItem(withTitle: "Create New Branch…", action: #selector(createBranchClicked), keyEquivalent: "")
        create.target = self
        let del = menu.addItem(withTitle: "Delete Branch…", action: nil, keyEquivalent: "")
        let delMenu = NSMenu()
        for b in branches where b != current {
            let di = delMenu.addItem(withTitle: b, action: #selector(deleteBranchClicked(_:)), keyEquivalent: "")
            di.target = self; di.representedObject = b
        }
        if delMenu.items.isEmpty { delMenu.addItem(withTitle: "No other branches", action: nil, keyEquivalent: "") }
        del.submenu = delMenu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: branchButton)
    }

    @objc private func checkoutBranch(_ item: NSMenuItem) {
        guard let b = item.representedObject as? String, let repo = model.activeSession?.url else { return }
        runGit({ Git.checkout(repo, b) }, failTitle: "Couldn’t switch to “\(b)”")
    }

    @objc private func createBranchClicked() {
        guard let repo = model.activeSession?.url else { return }
        let alert = NSAlert()
        alert.messageText = "Create New Branch"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "branch name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field   // focus the text field when the dialog appears
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        runGit({ Git.createBranch(repo, name) }, failTitle: "Couldn’t create “\(name)”")
    }

    @objc private func deleteBranchClicked(_ item: NSMenuItem) {
        guard let b = item.representedObject as? String, let repo = model.activeSession?.url else { return }
        // Always confirm (merged-check upfront so it's a single, appropriately-worded dialog).
        DispatchQueue.global().async {
            let merged = Git.isMerged(repo, b)
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Delete branch “\(b)”?"
                a.alertStyle = .warning
                if !merged {
                    a.informativeText = "“\(b)” isn’t fully merged — deleting it may discard commits that aren’t on any other branch."
                }
                a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                self.runGit({ Git.deleteBranch(repo, b, force: !merged).error }, failTitle: "Couldn’t delete “\(b)”")
            }
        }
    }

    /// Run a git mutation off-main; on failure show the error, then refresh the branch label now (don't
    /// wait for the FS poll, which won't fire when the old and new branches point at the same commit).
    private func runGit(_ op: @escaping () -> String?, failTitle: String) {
        DispatchQueue.global().async {
            let err = op()
            DispatchQueue.main.async {
                if let err, !err.isEmpty { self.showError(failTitle, err) }
                self.refreshBranch()
            }
        }
    }

    private func refreshBranch() {
        guard let repo = model.activeSession?.url else { return }
        DispatchQueue.global().async {
            let b = Git.branch(repo)
            DispatchQueue.main.async { self.model.activeSession?.gitBranch = b }
        }
    }

    private func showError(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.alertStyle = .warning
        a.addButton(withTitle: "OK"); a.runModal()
    }

    // MARK: - Build

    private func buildUI() {
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        updateDockerIcon()
        dockerButton.imagePosition = .imageOnly
        dockerButton.contentTintColor = StatusBarView.fg
        dockerButton.target = self; dockerButton.action = #selector(dockerClicked)
        dockerButton.toolTip = "Docker"

        updateBranchIcon()
        branchButton.imagePosition = .imageLeading
        branchButton.contentTintColor = StatusBarView.fg
        branchButton.target = self; branchButton.action = #selector(branchClicked)
        branchButton.toolTip = "Switch / create / delete branch"
        setContentHuggingPriority(.defaultHigh, for: .vertical)   // size to intrinsic height, don't stretch

        for (b, sel, tip) in [(lnColButton, #selector(goToLineClicked), "Go to Line… (⌘P then :)"),
                              (indentButton, #selector(indentClicked), "Select indentation"),
                              (eolButton, #selector(eolClicked), "Select line ending"),
                              (langButton, #selector(langClicked), "Select language mode")] {
            b.target = self; b.action = sel; b.toolTip = tip
        }

        updateShortcutsIcon()
        shortcutsButton.contentTintColor = StatusBarView.fg
        shortcutsButton.target = self; shortcutsButton.action = #selector(shortcutsClicked)
        shortcutsButton.toolTip = "Keyboard shortcuts"

        let left = NSStackView(views: [dockerButton, branchButton, resourceLabel])
        left.spacing = 12; left.alignment = .centerY
        // Editor items (which hide for non-editor tabs) + the always-visible shortcuts icon at the far right.
        let right = NSStackView(views: editorItems + [shortcutsButton])
        right.spacing = 14; right.alignment = .centerY
        for s in [left, right] { s.translatesAutoresizingMaskIntoConstraints = false; addSubview(s) }

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static let fg = NSColor(white: 0.62, alpha: 1)

    /// A flat, label-looking clickable item (pointing-hand cursor via PointerButton).
    private static func flatButton() -> PointerButton {
        let b = PointerButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.setButtonType(.momentaryChange)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func setTitle(_ b: NSButton, _ s: String) {
        b.attributedTitle = NSAttributedString(string: s, attributes: [
            .foregroundColor: StatusBarView.fg, .font: NSFont.systemFont(ofSize: statusFontSize)])
    }

    private func updateBranchIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: statusFontSize, weight: .regular)
        branchButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
            .withSymbolConfiguration(cfg)
    }

    @objc private func dockerClicked() { DockerHook.toggle?() }

    private func updateDockerIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: statusFontSize + 1, weight: .regular)
        dockerButton.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Docker")?
            .withSymbolConfiguration(cfg)
    }

    @objc private func shortcutsClicked() { ShortcutsWindowController.shared.show() }

    private func updateShortcutsIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: statusFontSize + 1, weight: .regular)
        shortcutsButton.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard shortcuts")?
            .withSymbolConfiguration(cfg)
    }
}
