import AppKit
import Combine

/// Hooks the chat tab needs from the app shell (wired by `CenterViewController`).
enum ChatHook {
    /// Continue a chat tab's conversation in Claude's terminal UI (converts the tab in place).
    static var openInTerminal: ((String) -> Void)?
    /// Fork a chat tab into a new chat tab (optional title) — `/fork`.
    static var fork: ((_ tabID: String, _ title: String?) -> Void)?
    /// Open a file in an editor tab of the chat's session — `/memory`.
    static var openFile: ((_ tabID: String, _ path: String) -> Void)?
    /// The chat tab's current title (for /export).
    static var tabTitle: ((String) -> String?)?
}

/// A chat tab: Claude Code rendered natively instead of in a terminal. Transcript on top; below it, in a
/// column matching the transcript, the background-tasks panel, the pending prompt card, the activity line,
/// the message box, and the status line. Owns no protocol logic — `ChatSession` does; this maps session
/// changes onto views and user input onto session intents.
final class ChatViewController: NSViewController, ChatSessionObserver {
    let tabID: String
    let session: ChatSession
    private let settings: Settings
    private weak var repo: Session?

    private var transcript: ChatTranscriptView!
    private let promptPanel = ChatPromptPanel()
    private let tasksPanel = ChatTasksPanel()
    private let activity = ChatActivityBar()
    private let input = ChatInputView()
    private let footer = ChatFooterView()
    private let picker = ChatPickerPanel()
    private let sidePanel = ChatSidePanel()
    /// The chat's own questions (rewind what, turn on bypass, another model) — a card like Claude's prompts.
    private let confirmPanel = ChatPromptPanel()
    /// What the picker is showing (nil = hidden).
    private enum PickerKind: String { case resume, rewind, memory }
    private var pickerKind: PickerKind?
    private var lastEscape: Date?
    private var style: ChatStyle
    private var cancellables = Set<AnyCancellable>()
    private var tick: Timer?
    private var tasksVisible = false
    private var tasksSignature = ""
    private var didInitialLoad = false
    private var files: [String] = []
    private var filesLoadedAt: Date?
    private var portScanAt: Date?
    private var contextFetched = false

    init(tab: Tab, repo: Session, settings: Settings) {
        self.tabID = tab.id
        self.repo = repo
        self.settings = settings
        self.session = ChatStore.shared.session(for: tab, cwd: repo.url, args: tab.args)
        self.style = ChatStyle(size: CGFloat(settings.fontSize))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        transcript = ChatTranscriptView(session: session, style: style, cwd: session.cwd)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.onToggle = { [weak self] id in self?.session.toggleExpanded(itemID: id) }
        transcript.onLoadEarlier = { [weak self] in self?.session.loadEarlier() }
        transcript.onTypeAhead = { [weak self] e in self?.input.typeAhead(e) }
        root.addSubview(transcript)

        promptPanel.onAnswer = { [weak self] a in self?.answer(a) }
        tasksPanel.onStop = { [weak self] id in self?.session.stopTask(id) }
        tasksPanel.onClearFinished = { [weak self] in self?.session.clearFinishedTasks() }
        tasksPanel.onClose = { [weak self] in self?.setTasksVisible(false) }
        activity.onRestart = { [weak self] in self?.session.restart() }
        activity.onTrust = { [weak self] in self?.session.trustAndStart(); self?.input.focus() }

        input.onSend = { [weak self] t, images in self?.send(t, images: images) }
        input.onEscape = { [weak self] in self?.escape() }
        input.onStop = { [weak self] in self?.session.interrupt() }
        input.onCycleMode = { [weak self] in self?.cycleMode() }
        input.commands = { [weak self] in
            let claude = self?.session.commands ?? []
            let names = Set(claude.map { $0.name.lowercased() })
            return claude + ChatSession.localCommands.filter { !names.contains($0.name) }
        }
        input.files = { [weak self] in self?.fileList() ?? [] }

        footer.onCycleMode = { [weak self] in self?.cycleMode() }
        footer.onPickMode = { [weak self] m in self?.changeMode(to: m) }
        footer.onPickModel = { [weak self] m in self?.session.setModel(m) }
        footer.onPickEffort = { [weak self] l in self?.session.setEffort(l) }
        footer.onFastMode = { [weak self] on in self?.session.setFastMode(on) }
        footer.onOtherModel = { [weak self] in self?.askOtherModel() }
        footer.onResume = { [weak self] in self?.showPicker(.resume) }
        footer.onRemote = { [weak self] on in self?.session.setRemoteControl(on) }
        picker.onPick = { [weak self] id in self?.picked(id) }
        picker.onClose = { [weak self] in self?.closePicker() }
        sidePanel.onClose = { [weak self] in self?.closeSide() }
        footer.onContext = { [weak self] anchor in self?.showContextBreakdown(from: anchor) }
        footer.onTasks = { [weak self] in self?.setTasksVisible(!(self?.tasksVisible ?? true)) }
        footer.onOpenTerminal = { [weak self] in self?.openInTerminal() }

        let bottom = NSStackView(views: [tasksPanel, picker, sidePanel, confirmPanel, promptPanel, activity, input, footer])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        bottom.detachesHiddenViews = true
        bottom.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottom)
        for v in [tasksPanel, picker, sidePanel, confirmPanel, promptPanel, activity, input, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        }
        tasksPanel.isHidden = true
        picker.isHidden = true
        sidePanel.isHidden = true
        confirmPanel.isHidden = true
        promptPanel.isHidden = true

        // The bottom column tracks the transcript's column (max 920pt, centered) so everything lines up.
        let colWidth = bottom.widthAnchor.constraint(equalToConstant: ChatRowGeometry.maxColumn)
        colWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),
            bottom.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            colWidth,
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.observer = self
        settings.$fontSize.dropFirst().receive(on: RunLoop.main).sink { [weak self] size in
            guard let self else { return }
            self.style = ChatStyle(size: CGFloat(size))
            self.input.setFontSize(CGFloat(size))
            self.transcript.setStyle(self.style)
            self.refreshChrome()
        }.store(in: &cancellables)
        input.setFontSize(CGFloat(settings.fontSize))
        _ = fileList()   // warm the @-completion list (one `git ls-files`, off-main)
        if session.runState == .notStarted { session.start() }
        refreshChrome()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialLoad, transcript.bounds.width > 10 {
            didInitialLoad = true
            transcript.layoutSubtreeIfNeeded()
            transcript.reloadAll()
        }
    }

    func focusInput() {
        if !confirmPanel.isHidden { confirmPanel.focusCard() }
        else if session.prompt != nil { view.window?.makeFirstResponder(promptPanel) } else { input.focus() }
    }

    deinit { tick?.invalidate() }

    // MARK: - Intents

    private func send(_ text: String, images: [ChatAttachment] = []) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/") {
            let parts = t.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if runLocal(parts.first?.lowercased() ?? "", arg) { return }
        }
        transcript.scrollToBottom()
        session.send(text, images: images)
    }

    /// Commands that need the chat's own UI rather than Claude (pickers, the clipboard, new tabs, files).
    /// Returns false to pass the text on to the session (which handles the rest or sends it to Claude).
    private func runLocal(_ name: String, _ arg: String) -> Bool {
        switch name {
        case "model" where arg.isEmpty, "effort" where arg.isEmpty: footerModelMenu()
        case "effort": session.setEffort(arg.lowercased())
        case "resume" where arg.isEmpty, "continue": showPicker(.resume)
        case "fast": session.setFastMode(session.fastModeState != "on")
        case "tasks", "bashes": setTasksVisible(true)
        case "context" where session.runState == .running: showContextBreakdown(from: nil)
        case "rewind", "checkpoint": showPicker(.rewind)
        case "fork", "branch": fork(named: arg)
        case "copy": copyReply(arg)
        case "export": export(to: arg)
        case "memory": showPicker(.memory)
        case "btw": askSide(arg)
        case "plan": plan(arg)
        default: return false
        }
        return true
    }

    private func footerModelMenu() { footer.showModelMenu() }

    /// Mode changes from the menu or ⇧⇥. Bypass runs every tool without asking, so the first time it's
    /// turned on (per install) it's confirmed — Claude's own terminal UI asks once too (and defaults to No).
    /// Declining from ⇧⇥ moves on to the mode after bypass, so the cycle isn't stuck in front of it.
    private func changeMode(to mode: String, cycling: Bool = false) {
        guard mode == "bypassPermissions", !UserDefaults.standard.bool(forKey: Self.bypassAckKey) else {
            session.setPermissionMode(mode); return
        }
        let no = { [weak self] in
            guard let self, cycling else { return }
            self.session.setPermissionMode(self.session.mode(after: mode))
        }
        ask(ChatLocalCard(
            title: "Turn on bypass permissions?",
            detail: "Claude will edit files and run commands in this chat without asking. Use it only in a folder you trust. You won’t be asked again.",
            choices: [.init(title: cycling ? "No, skip it" : "No") { no() },
                      .init(title: "Yes, bypass permissions") { [weak self] in
                          UserDefaults.standard.set(true, forKey: Self.bypassAckKey)
                          self?.session.setPermissionMode(mode)
                      }],
            hint: "↑↓ select · ⏎ confirm · esc no", onCancel: no, affirmative: 1))
    }
    private static let bypassAckKey = "chat.bypassAcknowledged"

    private func cycleMode() { changeMode(to: session.nextMode, cycling: true) }

    private func askOtherModel() {
        ask(ChatLocalCard(
            title: "Use another model", detail: "A model id or alias — e.g. claude-opus-4-8, sonnet[1m].", choices: [],
            field: ("model id", { [weak self] name in
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { self?.session.setModel(n) }
            }),
            hint: "⏎ switch · esc cancel", onCancel: {}))
    }

    /// Show one of the chat's own questions as a card above the box (never a modal). Each choice closes it
    /// first; esc cancels. The harness's canned answers pick without showing it.
    private func ask(_ card: ChatLocalCard) {
        var card = card
        let close = { [weak self] in self?.closeAsk() }
        card.choices = card.choices.map { c in ChatLocalCard.Choice(title: c.title, detail: c.detail) { close(); c.action() } }
        if let f = card.field { card.field = (f.placeholder, { text in close(); f.action(text) }) }
        let cancel = card.onCancel
        card.onCancel = { close(); cancel() }
        if let i = ChatConfirm.debugChoice, card.choices.indices.contains(i) { card.choices[i].action(); return }
        if let ok = ChatConfirm.debugResponse {
            if ok, card.choices.indices.contains(card.affirmative) { card.choices[card.affirmative].action() } else { card.onCancel() }
            return
        }
        if let t = ChatConfirm.debugText, let f = card.field { f.action(t); return }
        confirmPanel.showLocal(card, style: style)
        confirmPanel.isHidden = false
        DispatchQueue.main.async { [weak self] in self?.confirmPanel.focusCard() }
    }

    private func closeAsk() {
        confirmPanel.isHidden = true
        confirmPanel.clear()
        focusInput()        // the box — or Claude's prompt card, if one came in meanwhile
    }

    // MARK: - Picker (/resume, /rewind, /memory)

    private func showPicker(_ kind: PickerKind) {
        pickerKind = kind
        picker.isHidden = false
        let size = CGFloat(settings.fontSize)
        switch kind {
        case .resume:
            picker.present(title: "Resume a conversation", placeholder: "Search by title…", fontSize: size)
            let cwd = session.cwd, current = session.claudeSessionId
            DispatchQueue.global(qos: .userInitiated).async {
                let entries = ChatResume.list(cwd: cwd, excluding: current)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pickerKind == .resume else { return }
                    self.picker.setEntries(entries.map { .init(id: $0.id, title: $0.title, detail: ChatResume.detail($0)) },
                                           empty: "No other conversations in this folder yet.")
                }
            }
        case .rewind:
            picker.present(title: "Rewind — go back to before a message", placeholder: "Search your messages…", fontSize: size)
            // Oldest at the top, the latest at the bottom next to the box (and selected) — as in the terminal UI.
            let running = session.runState == .running
            let targets = running ? session.rewindTargets : []
            picker.setEntries(targets.enumerated().map { i, item in
                let line = item.text.split(separator: "\n").first.map(String.init) ?? item.text
                return .init(id: item.uuid ?? "", title: line.count > 140 ? String(line.prefix(139)) + "…" : line,
                             detail: i == 0 ? "latest" : "\(i) before latest")
            }.reversed(), empty: running ? "No messages to rewind to yet." : "Claude isn’t running — restart it (or send a message) first.",
                              newestLast: true)
        case .memory:
            picker.present(title: "Memory — open a CLAUDE.md in the editor", placeholder: "Filter…", fontSize: size)
            let fm = FileManager.default
            picker.setEntries(ChatMemory.files(cwd: session.cwd).map { f in
                let where_ = ChatRender.displayPath(f.path, cwd: session.cwd)
                return .init(id: f.path, title: f.title,
                             detail: where_ + " · " + (fm.fileExists(atPath: f.path) ? f.note : "new file"))
            }, empty: "")
        }
        DispatchQueue.main.async { [weak self] in self?.picker.focus() }
    }

    private func closePicker() {
        pickerKind = nil
        picker.isHidden = true
        input.focus()
    }

    private func picked(_ id: String) {
        guard let kind = pickerKind else { return }
        closePicker()
        switch kind {
        case .resume: session.switchConversation(to: id)
        case .rewind: confirmRewind(id)
        case .memory:
            guard ChatMemory.ensure(id) else { session.addNotice("Couldn’t create \(id)", error: true); return }
            ChatHook.openFile?(tabID, id)
        }
    }

    // MARK: - /rewind, /fork, /copy, /export

    /// Esc dismisses a side answer, stops a `!` command, or stops Claude while it works; esc twice on an
    /// empty box opens /rewind (the terminal UI's keys).
    private func escape() {
        if !confirmPanel.isHidden { confirmPanel.cancel(); return }
        if !sidePanel.isHidden { closeSide(); return }
        if session.shellRunning { session.stopShell(); return }
        if session.isWorking || session.prompt != nil { lastEscape = nil; session.interrupt(); return }
        let now = Date()
        if let last = lastEscape, now.timeIntervalSince(last) < 0.8, input.text.isEmpty {
            lastEscape = nil
            showPicker(.rewind)
        } else {
            lastEscape = now
        }
    }

    /// Ask what to restore (code and/or conversation), after a dry run shows what code would change.
    private func confirmRewind(_ uuid: String) {
        guard let item = session.items.first(where: { $0.uuid == uuid }) else { return }
        let first = item.text.split(separator: "\n").first.map(String.init) ?? item.text
        let short = first.count > 60 ? String(first.prefix(59)) + "…" : first
        session.previewRewind(uuid) { [weak self] changes, unavailable in
            guard let self else { return }
            let rewind = { [weak self] (code: Bool, conversation: Bool) in
                self?.session.rewind(to: uuid, code: code, conversation: conversation) { [weak self] prefill in
                    guard let self else { return }
                    if let prefill { self.input.text = prefill }
                    self.input.focus()
                }
            }
            let back = "this message and everything after it are removed; the message goes back into the box"
            var choices: [ChatLocalCard.Choice]
            let detail: String
            if let c = changes, !c.files.isEmpty {
                let names = c.files.prefix(5).map { ChatRender.displayPath($0, cwd: self.session.cwd) }.joined(separator: ", ")
                    + (c.files.count > 5 ? " and \(c.files.count - 5) more" : "")
                detail = "\(c.files.count) file\(c.files.count == 1 ? "" : "s") changed since then (+\(c.insertions) −\(c.deletions)): \(names)"
                choices = [
                    .init(title: "Restore code and conversation", detail: "Files go back to how they were; " + back) { rewind(true, true) },
                    .init(title: "Restore conversation", detail: "Files stay as they are; " + back) { rewind(false, true) },
                    .init(title: "Restore code", detail: "Files go back; the conversation stays as it is") { rewind(true, false) },
                ]
            } else {
                detail = unavailable.map { "Code can’t be restored: \($0)" } ?? "No files changed since this message."
                choices = [.init(title: "Restore conversation", detail: back.prefix(1).uppercased() + back.dropFirst()) { rewind(false, true) }]
            }
            choices.append(.init(title: "Never mind") {})
            self.ask(ChatLocalCard(title: "Rewind to before “\(short)”?", detail: detail, choices: choices,
                                   hint: "↑↓ select · ⏎ confirm · 1–\(choices.count) pick · esc never mind", onCancel: {}))
        }
    }

    /// `/btw <question>`: answered in the side card from this conversation's context, without joining it —
    /// also while Claude is busy with something else.
    private func askSide(_ question: String) {
        guard !question.isEmpty else {
            session.addNotice("Ask with /btw <question> — Claude answers from this conversation without adding to it.")
            return
        }
        sidePanel.ask(question, style: style)
        sidePanel.isHidden = false
        session.askSide(question) { [weak self] answer, error in
            guard let self, !self.sidePanel.isHidden, self.sidePanel.question == question else { return }
            if let answer { self.sidePanel.setAnswer(answer, style: self.style) }
            else { self.sidePanel.setError(error ?? "No answer.", style: self.style) }
        }
    }

    private func closeSide() {
        session.cancelSide()
        sidePanel.isHidden = true
        input.focus()
    }

    /// `/plan` switches to plan mode (`/plan <task>` also sends the task); `/plan open` — or `/plan` when
    /// already planning — opens the session's plan file in an editor tab.
    private func plan(_ arg: String) {
        if arg.lowercased() == "open" || (arg.isEmpty && session.permissionMode == "plan") { openPlan(); return }
        if session.permissionMode != "plan" {
            changeMode(to: "plan")
            session.addNotice("Plan mode on — Claude researches and proposes a plan before changing anything (⇧⇥ to leave)")
        }
        if !arg.isEmpty { transcript.scrollToBottom(); session.send(arg) }
    }

    private func openPlan() {
        session.fetchPlan { [weak self] path, error in
            guard let self else { return }
            if let path { ChatHook.openFile?(self.tabID, path); return }
            self.session.addNotice(error.map { "Couldn’t read the plan: \($0)" }
                                   ?? "No plan yet — in plan mode Claude writes one before changing anything.")
        }
    }

    private func fork(named name: String) {
        guard session.claudeSessionId != nil else {
            session.addNotice("Nothing to fork yet — send a message first.")
            return
        }
        ChatHook.fork?(tabID, name.isEmpty ? nil : name)
    }

    /// `/copy [n]`: Claude's latest reply (or the n-th latest) to the clipboard.
    private func copyReply(_ arg: String) {
        let n = max(1, Int(arg) ?? 1)
        let replies = session.items.filter { $0.kind == .assistant && !$0.streaming && !$0.text.isEmpty }
        guard replies.count >= n else {
            session.addNotice(replies.isEmpty ? "No reply to copy yet." : "Only \(replies.count) repl\(replies.count == 1 ? "y is" : "ies are") loaded.")
            return
        }
        let text = replies[replies.count - n].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.addNotice("Copied \(n == 1 ? "Claude’s last reply" : "reply \(n) back") to the clipboard (\(text.count) characters)")
    }

    /// `/export [file]`: the whole conversation as Markdown — to `file` (relative to the chat's folder), or
    /// wherever the save panel says.
    private func export(to arg: String) {
        let title = ChatHook.tabTitle?(tabID) ?? "Chat"
        let cwd = session.cwd
        session.loadFullHistory { [weak self] items in
            guard let self else { return }
            let markdown = ChatExport.markdown(items, title: title, cwd: cwd)
            let write = { [weak self] (path: String) in
                do {
                    try markdown.write(toFile: path, atomically: true, encoding: .utf8)
                    self?.session.addNotice("Exported the conversation to \(path)")
                } catch {
                    self?.session.addNotice("Couldn’t export: \(error.localizedDescription)", error: true)
                }
            }
            if !arg.isEmpty { write(ChatExport.resolve(arg, cwd: cwd)); return }
            if let p = ChatConfirm.debugSavePath { write(p); return }
            let panel = NSSavePanel()
            panel.directoryURL = URL(fileURLWithPath: cwd)
            panel.nameFieldStringValue = ChatExport.defaultName(title: title)
            panel.canCreateDirectories = true
            guard let window = self.view.window else { return }
            panel.beginSheetModal(for: window) { r in
                if r == .OK, let url = panel.url { write(url.path) }
            }
        }
    }

    /// The card, or one of its text rows (the field editor editing it sits inside the card).
    private func inPromptPanel(_ r: NSResponder?) -> Bool {
        guard let v = r as? NSView else { return false }
        return v === promptPanel || v.isDescendant(of: promptPanel)
    }

    private func answer(_ a: ChatSession.PromptAnswer) {
        session.answer(a)
        promptPanel.clear()
        input.focus()
    }

    func openInTerminal() {
        guard session.claudeSessionId != nil else {
            session.addNotice("Send a message first — there’s no conversation to continue in the terminal yet.")
            return
        }
        ChatHook.openInTerminal?(tabID)
    }

    private func setTasksVisible(_ on: Bool) {
        tasksVisible = on
        tasksPanel.isHidden = !on
        tasksSignature = ""
        refreshChrome()
    }

    // MARK: - ChatSessionObserver

    func chatItemsReset() { transcript.purgeCache(); transcript.reloadAll() }
    func chatItemsAppended(_ range: Range<Int>) { transcript.appended(range) }
    func chatItemsPrepended(_ count: Int) { transcript.prepended(count) }
    func chatItemsTruncated() { transcript.reloadAll(); transcript.scrollToBottom() }
    func chatItemChanged(at index: Int) { transcript.changed(index) }
    /// State changes arrive with every stream batch; the chrome (status line, activity, prompt card) needs
    /// far fewer repaints — coalesce to one refresh per ~0.1 s. Prompts still show within that window.
    func chatStateChanged() {
        guard !chromePending else { return }
        chromePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.chromePending = false
            self?.refreshChrome()
        }
    }
    private var chromePending = false

    private func refreshChrome() {
        guard isViewLoaded else { return }
        let size = CGFloat(settings.fontSize)
        activity.update(session, fontSize: size)
        activity.isHidden = activity.textShown.isEmpty
        input.working = session.isWorking
        footer.update(session, branch: repo?.gitBranch, fontSize: max(10, size - 2))
        transcript.stateChanged()

        if let p = session.prompt {
            let isNew = promptPanel.requestID != p.requestID
            promptPanel.show(p, style: style, cwd: session.cwd)
            promptPanel.isHidden = false
            // A new card takes the keyboard (⏎/esc/digits) unless you're typing somewhere else entirely.
            let fr = view.window?.firstResponder
            if isNew, fr === input.textView || fr is ChatRowTextView || fr === view.window || inPromptPanel(fr) {
                view.window?.makeFirstResponder(promptPanel)
            }
        } else if !promptPanel.isHidden {
            promptPanel.isHidden = true
            promptPanel.clear()
            if inPromptPanel(view.window?.firstResponder) { input.focus() }
        }

        if tasksVisible {
            let sig = session.tasks.map { "\($0.id)\($0.status)\($0.ports)\($0.outputFile ?? "")\($0.activity ?? "")\(Int(Date().timeIntervalSince($0.startedAt)))" }.joined()
            if sig != tasksSignature {
                tasksSignature = sig
                tasksPanel.update(session.tasks, fontSize: size)
            }
        }
        if !contextFetched, session.runState == .running, !session.models.isEmpty {
            contextFetched = true
            session.fetchContextUsage { [weak self] r, _ in self?.session.applyContextUsage(r) }
        }
        updateTick()
    }

    /// A 1 s tick only while something on screen changes with time: the activity timer, running tasks'
    /// elapsed time / log tail / port scan, the usage-reset countdowns. Idle chat → no timer.
    private func updateTick() {
        let needed = session.isWorking || session.tasks.contains(where: \.isRunning)
        if needed, tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.onTick() }
        } else if !needed, tick != nil {
            tick?.invalidate(); tick = nil
            onTick()
        }
    }

    private func onTick() {
        activity.update(session, fontSize: CGFloat(settings.fontSize))
        activity.isHidden = activity.textShown.isEmpty
        if tasksVisible {
            tasksSignature = ""
            refreshTasksOnly()
            tasksPanel.refreshLog()
        }
        scanPortsIfNeeded()
    }

    private func refreshTasksOnly() {
        tasksPanel.update(session.tasks, fontSize: CGFloat(settings.fontSize))
    }

    /// Every 3 s while a background shell runs: which TCP ports its processes listen on.
    private func scanPortsIfNeeded() {
        guard let pid = session.processID, session.tasks.contains(where: { $0.isRunning && $0.isShell }) else { return }
        if let at = portScanAt, Date().timeIntervalSince(at) < 3 { return }
        portScanAt = Date()
        let shells = session.runningShells
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ports = ChatPortScanner.scan(claudePID: pid, shells: shells)
            DispatchQueue.main.async { self?.session.setPorts(ports) }
        }
    }

    // MARK: - @file completion source

    private func fileList() -> [String] {
        if filesLoadedAt == nil || Date().timeIntervalSince(filesLoadedAt!) > 30 {
            filesLoadedAt = Date()
            let cwd = session.cwd
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let list = ChatFiles.list(cwd)
                DispatchQueue.main.async {
                    self?.files = list
                    self?.input.refreshCompletion()   // an `@` typed before the list arrived gets its matches now
                }
            }
        }
        return files
    }

    // MARK: - Context breakdown popover

    private func showContextBreakdown(from anchor: NSView?) {
        session.fetchContextUsage { [weak self] r, err in
            guard let self else { return }
            self.session.applyContextUsage(r)
            let vc = ChatContextPopover(usage: r, error: err, fontSize: CGFloat(self.settings.fontSize))
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = vc
            pop.appearance = NSAppearance(named: .darkAqua)
            let target = anchor ?? self.footer
            pop.show(relativeTo: target.bounds, of: target, preferredEdge: .maxY)
            self.lastContextText = vc.text
        }
    }
    private(set) var lastContextText = ""

    // MARK: - DEV harness

    func debugState() -> [String: Any] {
        let s = session
        var d: [String: Any] = [
            "run": "\(s.runState)", "working": s.isWorking, "activity": s.activity ?? "",
            "cid": s.claudeSessionId ?? "", "model": s.model ?? "", "mode": s.permissionMode,
            "contextUsed": s.contextUsed, "contextWindow": s.contextWindow, "contextPercent": s.contextPercent,
            "fiveHour": s.fiveHour.map { $0.utilization } ?? -1, "sevenDay": s.sevenDay.map { $0.utilization } ?? -1,
            "commands": s.commands.count, "models": s.models.map(\.value), "cost": s.totalCostUSD,
            "itemCount": s.items.count, "prompt": s.prompt.map { "\($0.kind):\($0.toolName)" } ?? "",
            "promptVisible": !promptPanel.isHidden, "promptCard": promptPanel.debugState, "tasksVisible": tasksVisible,
            "askVisible": !confirmPanel.isHidden, "askCard": confirmPanel.debugState,
            "attachments": input.attachments.map { ["n": $0.number, "bytes": $0.data.count, "type": $0.mediaType] },
            "inputSelection": "\(input.textView.selectedRange().location)+\(input.textView.selectedRange().length)",
            "tasks": s.tasks.map { ["id": $0.id, "type": $0.type, "desc": $0.description, "status": $0.status,
                                     "ports": $0.ports, "output": $0.outputFile ?? ""] as [String: Any] },
            "footer": footer.snapshot, "activityText": activity.textShown,
            "inputText": input.text, "queued": s.queuedTexts, "completion": input.completionTitles.prefix(8).map { $0 },
            "historyStart": s.historyStart.map { Int($0) } ?? -1, "canLoadEarlier": s.canLoadEarlier,
            "transcript": transcript.debugState(), "logText": String(tasksPanel.logText.suffix(300)),
            "contextPopover": lastContextText, "effort": s.effort ?? "", "fastMode": s.fastModeState ?? "",
            "fastReason": s.fastModeReason ?? "", "remoteURL": s.remoteURL ?? "", "modeCycle": s.modeCycle,
            "resumeVisible": pickerKind == .resume, "picker": pickerKind?.rawValue ?? "",
            "pickerEntries": picker.shown.prefix(12).map { "\($0.title) · \($0.detail)" }, "pickerSelected": picker.debugSelected,
            "copyButtons": transcript.debugCopyButtonCount(),
            "side": ["visible": !sidePanel.isHidden, "question": sidePanel.question, "answer": String(sidePanel.answer.prefix(300))],
            "shellRunning": s.shellRunning,
        ]
        d["items"] = s.items.suffix(40).map { i -> [String: Any] in
            var e: [String: Any] = ["id": i.id, "kind": "\(i.kind)", "text": String(i.text.prefix(300))]
            if let u = i.uuid { e["uuid"] = u }
            if !i.images.isEmpty { e["images"] = i.images.map { "\(Int($0.size.width))x\(Int($0.size.height))" } }
            if i.kind == .tool {
                e["tool"] = i.toolName; e["status"] = "\(i.toolStatus)"
                e["summary"] = ChatRender.toolSummary(i.toolName, i.toolInput, cwd: s.cwd)
                e["result"] = String((i.toolResult ?? "").prefix(200))
                e["subagent"] = "\(i.subagentSteps) \(i.subagentLast ?? "")"
            }
            if i.expanded { e["expanded"] = true }
            return e
        }
        return d
    }

    func debugSetInput(_ t: String) { input.text = t }
    func debugSubmitInput() { input.submit() }
    func debugSend(_ t: String) { send(t) }
    func debugPromptPress(_ label: String?) { promptPanel.debugPress(label) }
    func debugPromptFeedback(_ s: String) { promptPanel.debugSetFeedback(s) }
    func debugDeny() { answer(.deny(nil)) }
    func debugPromptDeny() { promptPanel.debugDeny() }
    func debugAllowAlways() { answer(.allowAlways) }
    func debugToggleTasks() { setTasksVisible(!tasksVisible) }
    func debugShowLog(_ index: Int) {
        guard session.tasks.indices.contains(index) else { return }
        if !tasksVisible { setTasksVisible(true) }
        tasksPanel.showLog(session.tasks[index].id)
    }
    func debugStopTask(_ index: Int) { if session.tasks.indices.contains(index) { session.stopTask(session.tasks[index].id) } }
    func debugScrollBenchmark() -> [String: Any] { transcript.debugScrollBenchmark() }
    func debugScroll(_ f: CGFloat) { transcript.debugScroll(toFraction: f) }
    func debugVisibleText() -> String { transcript.debugVisibleText() }
    func debugToggleItem(_ index: Int) {
        let items = session.items
        let i = index < 0 ? items.count + index : index
        if items.indices.contains(i) { session.toggleExpanded(itemID: items[i].id) }
    }
    func debugContext() { showContextBreakdown(from: nil) }
    func debugShowResume() { showPicker(.resume) }
    func debugResumeEntries() -> [String] { picker.shown.map { "\($0.id) \($0.title)" } }
    func debugResumePick(_ i: Int) { picker.debugPick(i) }
    func debugPressCopy(_ n: Int) -> String? { transcript.debugPressCopy(n) }
    func debugCopyButtons() -> Int { transcript.debugCopyButtonCount() }
    func debugChangeMode(_ m: String) { changeMode(to: m) }
    func debugCycle() { cycleMode() }
    func debugPasteText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        input.focus()
        input.textView.paste(nil)
    }

    /// Raw image bytes under one pasteboard type and nothing else — how clipboard managers hand images over.
    func debugPasteImageData(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        input.focus()
        input.textView.paste(nil)
    }

    /// Put an image (or its file URL) on the clipboard and paste it into the box — the real paste path.
    func debugPasteImage(_ path: String, asFile: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if asFile { pb.writeObjects([URL(fileURLWithPath: path) as NSURL]) }
        else if let image = NSImage(contentsOfFile: path) { pb.writeObjects([image]) }
        input.focus()
        input.textView.paste(nil)
    }
    /// Would ⌘V even fire? AppKit greys out Edit ▸ Paste when the clipboard holds nothing the focused view
    /// claims to read, and a plain-text view claims only text — which is why an image-only clipboard did
    /// nothing at all. The `debugPaste*` calls above skip this step, so only this sees it.
    func debugPasteEnabled() -> String {
        input.focus()
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let matched = NSPasteboard.general.availableType(from: input.textView.readablePasteboardTypes)?.rawValue ?? "none"
        return "enabled=\(input.textView.validateMenuItem(item)) matched=\(matched) key=\(view.window?.isKeyWindow ?? false)"
    }

    /// Paste the way the Edit menu does it — down the responder chain, not straight at the text view.
    /// (`NSApp.sendAction` needs a key window, which a background harness run has not got, so start the
    /// walk at this window's first responder instead.)
    func debugMenuPaste() {
        input.focus()
        _ = view.window?.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil)
    }

    /// ⌘Z in the box — the marker/attachment bookkeeping has to survive it. `breakUndoCoalescing` first:
    /// typing leaves an open undo group, and `undo()` inside one throws.
    func debugUndo() {
        input.focus()
        input.textView.breakUndoCoalescing()
        input.textView.undoManager?.undo()
    }

    func debugOtherModel() { askOtherModel() }
    func debugKey(_ selector: Selector) { input.focus(); input.textView.doCommand(by: selector) }
}

/// Listening TCP ports under a chat's `claude` process, attributed to its background shell tasks.
enum ChatPortScanner {
    static func scan(claudePID: Int32, shells: [(id: String, command: String)]) -> [String: [Int]] {
        // Process tree: pid → (ppid, command)
        var parent: [Int32: Int32] = [:]
        var command: [Int32: String] = [:]
        for line in Shell.run("/bin/ps", ["-A", "-o", "pid=,ppid=,command="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            parent[pid] = pp
            command[pid] = parts.count > 2 ? String(parts[2]) : ""
        }
        // Descendants of claude, each mapped to its top-level ancestor (the task's shell, a child of claude).
        var top: [Int32: Int32] = [:]
        for pid in parent.keys {
            var p = pid, depth = 0
            while let pp = parent[p], pp != claudePID, pp > 1, depth < 32 { p = pp; depth += 1 }
            if parent[p] == claudePID { top[pid] = p }
        }
        guard !top.isEmpty else { return [:] }
        let pids = top.keys.map(String.init).joined(separator: ",")
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pids, "-Fpn"])
        var listening: [(Int32, Int)] = []
        var current: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                listening.append((current, port))
            }
        }
        var result: [String: [Int]] = [:]
        for (pid, port) in listening {
            guard let root = top[pid] else { continue }
            let cmd = (command[root] ?? "") + " " + (command[pid] ?? "")
            let owner = shells.first { !$0.command.isEmpty && cmd.contains($0.command) }
                ?? (shells.count == 1 ? shells.first : nil)
            if let owner, !(result[owner.id]?.contains(port) ?? false) { result[owner.id, default: []].append(port) }
        }
        return result.mapValues { $0.sorted() }
    }
}

/// Repo files for `@` completion: git's tracked + untracked-not-ignored list, else a bounded walk.
enum ChatFiles {
    static func list(_ cwd: String) -> [String] {
        let git = Shell.run(Env.resolve("git"), ["ls-files", "-co", "--exclude-standard"], cwd: cwd)
        if !git.isEmpty { return git.split(separator: "\n").prefix(50_000).map(String.init) }
        var out: [String] = []
        let base = URL(fileURLWithPath: cwd)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in e {
            if url.lastPathComponent == "node_modules" || url.lastPathComponent == ".build" { e.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(String(url.path.dropFirst(base.path.count + 1)))
            if out.count >= 20_000 { break }
        }
        return out
    }
}

/// The context popover: Claude's own breakdown (`get_context_usage`) as a small table.
final class ChatContextPopover: NSViewController {
    private(set) var text = ""
    private let usage: [String: Any]?
    private let error: String?
    private let fontSize: CGFloat

    init(usage: [String: Any]?, error: String?, fontSize: CGFloat) {
        self.usage = usage; self.error = error; self.fontSize = fontSize
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let s = NSMutableAttributedString()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)]
        let row: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular), .foregroundColor: NSColor(white: 0.78, alpha: 1)]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize - 2), .foregroundColor: NSColor(white: 0.5, alpha: 1)]
        if let u = usage {
            let total = u["totalTokens"] as? Int ?? 0, max = u["maxTokens"] as? Int ?? 0
            let pct = u["percentage"] as? Int ?? 0
            s.append(NSAttributedString(string: "Context · \(Self.k(total)) / \(Self.k(max)) tokens (\(pct)%)\n", attributes: title))
            for c in u["categories"] as? [[String: Any]] ?? [] {
                let name = c["name"] as? String ?? ""
                let tokens = c["tokens"] as? Int ?? 0
                let deferred = c["isDeferred"] as? Bool == true
                s.append(NSAttributedString(string: "\n\(name.padding(toLength: 26, withPad: " ", startingAt: 0))\(Self.k(tokens).leftPad(8))", attributes: deferred ? dim : row))
            }
            if let t = u["autoCompactThreshold"] as? Int, u["isAutoCompactEnabled"] as? Bool == true {
                s.append(NSAttributedString(string: "\n\nAuto-compacts at \(Self.k(t)) tokens", attributes: dim))
            }
        } else {
            s.append(NSAttributedString(string: error ?? "No context data", attributes: row))
        }
        text = s.string
        let label = NSTextField(labelWithAttributedString: s)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
        ])
        view = v
    }

    static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

/// Canned answers for the chat's in-card questions (the harness sets them to skip showing the card).
enum ChatConfirm {
    static var debugResponse: Bool?     // true → the card's affirmative choice, false → cancel
    static var debugText: String?       // the text row's answer
    static var debugChoice: Int?        // → this choice index
    static var debugSavePath: String?   // /export → this path instead of the save panel
}
