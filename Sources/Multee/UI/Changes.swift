import AppKit
import Combine

// MARK: - Changes model (polls staged + unstaged; runs git actions) — ported as-is.

final class ChangesModel: ObservableObject {
    @Published var staged: [FileEntry] = []
    @Published var unstaged: [FileEntry] = []
    @Published var stashCount = 0
    let repo: String
    private var timer: Timer?
    private var lastSig = ""

    init(repo: String) { self.repo = repo }

    func refresh() {
        let repo = self.repo
        DispatchQueue.global().async { [weak self] in
            let g = Git.statusGroups(repo)
            let stashes = Git.stashCount(repo)
            let sig = (g.staged + g.unstaged).map { "\($0.path)|\($0.status.rawValue)" }.joined(separator: "\n")
                + "#staged:\(g.staged.count)#stash:\(stashes)"
            DispatchQueue.main.async {
                guard let self, sig != self.lastSig else { return }
                self.lastSig = sig
                self.staged = g.staged
                self.unstaged = g.unstaged
                self.stashCount = stashes
            }
        }
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private func act(_ body: @escaping () -> Void) {
        DispatchQueue.global().async { body(); DispatchQueue.main.async { self.lastSig = ""; self.refresh() } }
    }
    func stage(_ p: String) { act { Git.stage(self.repo, p) } }
    func unstage(_ p: String) { act { Git.unstage(self.repo, p) } }
    func stageAll() { act { Git.stageAll(self.repo) } }
    func unstageAll() { act { Git.unstageAll(self.repo) } }
    func discard(_ f: FileEntry) { act { Git.discard(self.repo, f.path, f.status) } }
    func discardAll() { act { Git.discardAll(self.repo) } }
    func stash() { act { Git.stash(self.repo) } }
    func unstash() { act { Git.unstash(self.repo) } }
    func commit(_ msg: String, all: Bool) { act { if all { Git.stageAll(self.repo) }; Git.commit(self.repo, msg) } }
    func commitPush(_ msg: String, all: Bool) { act { if all { Git.stageAll(self.repo) }; Git.commit(self.repo, msg); Git.push(self.repo) } }
}

// MARK: - Changes view controller

final class ChangesViewController: NSViewController {
    let repo: String
    private let onOpenDiff: (String) -> Void
    private let onOpenFile: (String) -> Void
    private let model: ChangesModel
    private var cancellables = Set<AnyCancellable>()

    private let commitField = NSTextField()
    private let commitButton = NSButton()
    private let menuButton = NSButton()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No changes")

    init(repo: String, onOpenDiff: @escaping (String) -> Void, onOpenFile: @escaping (String) -> Void) {
        self.repo = repo
        self.onOpenDiff = onOpenDiff
        self.onOpenFile = onOpenFile
        self.model = ChangesModel(repo: repo)
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

        commitButton.title = "✓ Commit"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .regular
        commitButton.target = self
        commitButton.action = #selector(commitTapped)

        menuButton.title = "▾"
        menuButton.bezelStyle = .rounded
        menuButton.controlSize = .regular
        menuButton.target = self
        menuButton.action = #selector(commitMenuTapped)
        menuButton.setContentHuggingPriority(.required, for: .horizontal)

        let buttonRow = NSStackView(views: [commitButton, menuButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4
        commitButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let commitBar = NSStackView(views: [commitField, buttonRow])
        commitBar.orientation = .vertical
        commitBar.spacing = 6
        commitBar.alignment = .leading
        commitBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        commitBar.translatesAutoresizingMaskIntoConstraints = false

        // List
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = listStack

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
            listStack.topAnchor.constraint(equalTo: clip.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            listStack.widthAnchor.constraint(equalTo: clip.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
        model.start()
        rebuild()
    }

    func stop() { model.stop() }

    private var canCommit: Bool {
        !commitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!model.staged.isEmpty || !model.unstaged.isEmpty)
    }

    private func rebuild() {
        commitButton.isEnabled = canCommit
        menuButton.isEnabled = canCommit

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasChanges = !model.staged.isEmpty || !model.unstaged.isEmpty
        emptyLabel.isHidden = hasChanges
        guard hasChanges else { return }

        if !model.staged.isEmpty {
            listStack.addArrangedSubview(sectionHeader("STAGED CHANGES", model.staged.count, actions: [
                ("minus", "Unstage all", { [weak self] in self?.model.unstageAll() }),
            ]))
            for f in model.staged { addRow(f, staged: true) }
        }
        var changeActions: [(String, String, () -> Void)] = [
            ("tray.and.arrow.down", "Stash all changes", { [weak self] in self?.model.stash() }),
        ]
        if model.stashCount > 0 {
            changeActions.append(("tray.and.arrow.up", "Unstash (pop latest)", { [weak self] in self?.model.unstash() }))
        }
        changeActions.append(("arrow.uturn.backward", "Discard all changes", { [weak self] in self?.confirmDiscardAll() }))
        changeActions.append(("plus", "Stage all", { [weak self] in self?.model.stageAll() }))
        listStack.addArrangedSubview(sectionHeader("CHANGES", model.unstaged.count, actions: changeActions))
        for f in model.unstaged { addRow(f, staged: false) }
    }

    private func addRow(_ f: FileEntry, staged: Bool) {
        let row = ChangeRowView(
            file: f, staged: staged,
            onOpenDiff: { [weak self] in self?.onOpenDiff(f.path) },
            onOpenFile: { [weak self] in self?.onOpenFile(f.path) },
            onStageToggle: { [weak self] in staged ? self?.model.unstage(f.path) : self?.model.stage(f.path) },
            onDiscard: { [weak self] in self?.confirmDiscard(f) })
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
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
        let all = model.staged.isEmpty   // nothing staged ⇒ commit everything
        if push { model.commitPush(msg, all: all) } else { model.commit(msg, all: all) }
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
        if alert.runModal() == .alertFirstButtonReturn { model.discardAll() }
    }

    private func confirmDiscard(_ f: FileEntry) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to “\(f.path)”?"
        alert.informativeText = "This file's changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.discard(f) }
    }
}

// MARK: - One change row (hover reveals stage/discard/open actions)

private final class ChangeRowView: NSView {
    private let file: FileEntry
    private let staged: Bool
    private let onOpenDiff: () -> Void
    private let actions: NSStackView
    private var tracking: NSTrackingArea?

    init(file: FileEntry, staged: Bool, onOpenDiff: @escaping () -> Void, onOpenFile: @escaping () -> Void,
         onStageToggle: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.file = file
        self.staged = staged
        self.onOpenDiff = onOpenDiff
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
        actions.addArrangedSubview(ClosureButton(symbol: "arrow.uturn.backward", action: onDiscard))
        if file.status != .deleted {
            actions.addArrangedSubview(ClosureButton(symbol: "square.and.pencil", action: onOpenFile))
        }
        actions.addArrangedSubview(ClosureButton(symbol: staged ? "minus" : "plus", action: onStageToggle))

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
    override func mouseDown(with event: NSEvent) { onOpenDiff() }
}

/// Small SF-symbol icon button backed by a closure.
final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
