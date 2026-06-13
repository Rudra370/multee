import AppKit
import Combine

// MARK: - Changes view controller

final class ChangesViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: RepoStore
    private let onOpenDiff: (String) -> Void
    private let onOpenFile: (String) -> Void
    private var cancellables = Set<AnyCancellable>()

    private let commitField = NSTextField()
    private let commitButton = PointerButton()
    private let menuButton = PointerButton()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No changes")

    /// A virtualized list row: a section header, a file row, or a "…and N more" footer.
    private enum Item {
        case header(title: String, count: Int, actions: [(String, String, () -> Void)])
        case file(FileEntry, staged: Bool)
        case more(Int)
    }
    private var items: [Item] = []
    /// Max file rows rendered per section. The list is virtualized so this is a high safety net, not a
    /// normal limit — it only bites on pathological repos (thousands of changes) where drawing every
    /// row is pointless anyway. The section header still shows the true total count.
    private static let rowCap = 2000

    init(store: RepoStore, onOpenDiff: @escaping (String) -> Void, onOpenFile: @escaping (String) -> Void) {
        self.store = store
        self.onOpenDiff = onOpenDiff
        self.onOpenFile = onOpenFile
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.145, alpha: 1).cgColor

        // Commit bar
        commitField.placeholderString = "Commit message"
        commitField.font = .systemFont(ofSize: 12)
        commitField.isBezeled = true
        commitField.bezelStyle = .roundedBezel
        commitField.focusRingType = .none
        commitField.target = self
        commitField.action = #selector(commitFromField)
        commitField.delegate = self   // re-enable the Commit button as soon as a message is typed

        commitButton.title = "✓ Commit"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .regular
        commitButton.target = self
        commitButton.action = #selector(commitTapped)
        commitButton.toolTip = "Commit (auto-stages everything if nothing is staged)"

        menuButton.title = "▾"
        menuButton.bezelStyle = .rounded
        menuButton.controlSize = .regular
        menuButton.target = self
        menuButton.action = #selector(commitMenuTapped)
        menuButton.toolTip = "Commit / Commit & Push"
        menuButton.setContentHuggingPriority(.required, for: .horizontal)

        let buttonRow = NSStackView(views: [commitButton, menuButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4
        buttonRow.distribution = .fill
        commitButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commitButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        menuButton.widthAnchor.constraint(equalToConstant: 34).isActive = true   // small ▾, Commit fills the rest

        let commitBar = NSStackView(views: [commitField, buttonRow])
        commitBar.orientation = .vertical
        commitBar.spacing = 6
        commitBar.alignment = .leading
        commitBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        commitBar.translatesAutoresizingMaskIntoConstraints = false

        // List — a virtualized NSTableView. Only the ~visible rows are ever instantiated, so a repo
        // with thousands of changes can't hang the UI by laying out every row (the old NSStackView
        // built one view + constraint per file, which froze the app on large changesets).
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)   // single-click a file row → open its diff

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor(white: 0.4, alpha: 1)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        root.addSubview(commitBar)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            commitBar.topAnchor.constraint(equalTo: root.topAnchor),
            commitBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commitBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commitField.widthAnchor.constraint(equalTo: commitBar.widthAnchor, constant: -16),
            buttonRow.widthAnchor.constraint(equalTo: commitBar.widthAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: commitBar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Rebuild whenever the shared store's change data updates (the store owns the watcher + poll).
        store.$staged.combineLatest(store.$unstaged, store.$stashCount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    private var canCommit: Bool {
        !commitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!store.staged.isEmpty || !store.unstaged.isEmpty)
    }

    /// Live-update the Commit button as the user types (model polls don't fire on keystrokes).
    func controlTextDidChange(_ obj: Notification) {
        commitButton.isEnabled = canCommit
        menuButton.isEnabled = canCommit
    }

    private func rebuild() {
        commitButton.isEnabled = canCommit
        menuButton.isEnabled = canCommit

        var rows: [Item] = []
        if !store.staged.isEmpty {
            rows.append(.header(title: "STAGED CHANGES", count: store.staged.count, actions: [
                ("minus", "Unstage all", { [weak self] in self?.store.unstageAll() }),
            ]))
            appendFiles(store.staged, staged: true, into: &rows)
        }
        if !store.unstaged.isEmpty {
            var changeActions: [(String, String, () -> Void)] = [
                ("tray.and.arrow.down", "Stash all changes", { [weak self] in self?.store.stash() }),
            ]
            if store.stashCount > 0 {
                changeActions.append(("tray.and.arrow.up", "Unstash (pop latest)", { [weak self] in self?.store.unstash() }))
            }
            changeActions.append(("arrow.uturn.backward", "Discard all changes", { [weak self] in self?.confirmDiscardAll() }))
            changeActions.append(("plus", "Stage all", { [weak self] in self?.store.stageAll() }))
            rows.append(.header(title: "CHANGES", count: store.unstaged.count, actions: changeActions))
            appendFiles(store.unstaged, staged: false, into: &rows)
        }

        items = rows
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()   // cheap — builds only visible cells
    }

    private func appendFiles(_ files: [FileEntry], staged: Bool, into rows: inout [Item]) {
        for f in files.prefix(Self.rowCap) { rows.append(.file(f, staged: staged)) }
        if files.count > Self.rowCap { rows.append(.more(files.count - Self.rowCap)) }
    }

    private func sectionHeader(_ title: String, _ count: Int, actions: [(String, String, () -> Void)]) -> NSView {
        let label = NSTextField(labelWithString: "\(title)  \(count)")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(white: 0.5, alpha: 1)
        let buttons = actions.map { iconButton($0.0, $0.1, $0.2) }
        let stack = NSStackView(views: [label, NSView()] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 3, right: 8)
        return stack
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(symbol: symbol, action: action)
        b.toolTip = help
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    // MARK: Commit

    @objc private func commitFromField() { if canCommit { doCommit(push: false) } }
    @objc private func commitTapped() { if canCommit { doCommit(push: false) } }

    @objc private func commitMenuTapped() {
        guard canCommit else { return }
        let menu = NSMenu()
        let c = menu.addItem(withTitle: "Commit", action: #selector(menuCommit), keyEquivalent: ""); c.target = self
        let p = menu.addItem(withTitle: "Commit & Push", action: #selector(menuCommitPush), keyEquivalent: ""); p.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 2), in: menuButton)
    }
    @objc private func menuCommit() { doCommit(push: false) }
    @objc private func menuCommitPush() { doCommit(push: true) }

    private func doCommit(push: Bool) {
        let msg = commitField.stringValue
        let all = store.staged.isEmpty   // nothing staged ⇒ commit everything
        if push { store.commitPush(msg, all: all) } else { store.commit(msg, all: all) }
        commitField.stringValue = ""
        rebuild()
    }

    // MARK: Confirms

    private func confirmDiscardAll() {
        let alert = NSAlert()
        alert.messageText = "Discard ALL changes?"
        alert.informativeText = "Resets tracked files to HEAD and deletes untracked files. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.discardAll() }
    }

    private func confirmDiscard(_ f: FileEntry) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to “\(f.path)”?"
        alert.informativeText = "This file's changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.discard(f) }
    }

    // MARK: Virtualized list (NSTableView) — builds only the visible rows

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 28 }
        return 24
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case let .header(title, count, actions):
            return sectionHeader(title, count, actions: actions)
        case let .file(f, staged):
            return ChangeRowView(
                file: f, staged: staged,
                onOpenFile: { [weak self] in self?.onOpenFile(f.path) },
                onStageToggle: { [weak self] in staged ? self?.store.unstage(f.path) : self?.store.stage(f.path) },
                onDiscard: { [weak self] in self?.confirmDiscard(f) })
        case let .more(n):
            let label = NSTextField(labelWithString: "   …and \(n) more")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(white: 0.5, alpha: 1)
            return label
        }
    }

    /// Single-click on a file row opens its diff (header / "more" rows are inert).
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count, case let .file(f, _) = items[row] else { return }
        onOpenDiff(f.path)
    }
}

// MARK: - One change row (hover reveals stage/discard/open actions)

private final class ChangeRowView: PointerView {
    private let file: FileEntry
    private let staged: Bool
    private let actions: NSStackView
    private var tracking: NSTrackingArea?

    init(file: FileEntry, staged: Bool, onOpenFile: @escaping () -> Void,
         onStageToggle: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.file = file
        self.staged = staged
        self.actions = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true

        let name = NSTextField(labelWithString: (file.path as NSString).lastPathComponent)
        name.font = .systemFont(ofSize: 13)
        let color = nsStatusColor(file.status)
        if file.status == .deleted {
            name.attributedStringValue = NSAttributedString(string: name.stringValue, attributes: [
                .foregroundColor: color, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
        } else {
            name.textColor = color
        }
        name.lineBreakMode = .byTruncatingTail

        let dir = (file.path as NSString).deletingLastPathComponent
        let dirLabel = NSTextField(labelWithString: dir)
        dirLabel.font = .systemFont(ofSize: 11)
        dirLabel.textColor = NSColor(white: 0.4, alpha: 1)
        dirLabel.lineBreakMode = .byTruncatingHead
        dirLabel.isHidden = dir.isEmpty

        let badge = NSTextField(labelWithString: Self.badge(file.status))
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = color
        badge.setContentHuggingPriority(.required, for: .horizontal)

        actions.orientation = .horizontal
        actions.spacing = 2
        actions.isHidden = true
        func actionButton(_ symbol: String, _ tip: String, _ run: @escaping () -> Void) -> ClosureButton {
            let b = ClosureButton(symbol: symbol, action: run)
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true   // larger hit area than the bare glyph
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return b
        }
        actions.addArrangedSubview(actionButton("arrow.uturn.backward", "Discard changes", onDiscard))
        if file.status != .deleted {
            actions.addArrangedSubview(actionButton("square.and.pencil", "Open file to edit", onOpenFile))
        }
        actions.addArrangedSubview(actionButton(staged ? "minus" : "plus", staged ? "Unstage" : "Stage", onStageToggle))

        let stack = NSStackView(views: [name, dirLabel, NSView(), actions, badge])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func badge(_ s: GitStatus) -> String {
        switch s {
        case .new: return "A"; case .modified: return "M"; case .deleted: return "D"
        case .renamed: return "R"; case .conflict: return "C"; default: return "•"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        actions.isHidden = false
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        actions.isHidden = true
    }
}

/// Small SF-symbol icon button backed by a closure (pointing-hand cursor via PointerButton).
final class ClosureButton: PointerButton {
    private let handler: () -> Void
    init(symbol: String, pointSize: CGFloat? = nil, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let pointSize {
            img = img?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        image = img
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .inline
        contentTintColor = NSColor(white: 0.62, alpha: 1)
        target = self
        self.action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
