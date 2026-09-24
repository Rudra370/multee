import Foundation

/// The live state of one chat tab: its `claude` process, transcript items, and everything the chrome shows
/// (model, permission mode, context use, rate limits, background tasks, the pending prompt). Main thread
/// only. Reduces Claude's stream-json events into items and state, and turns UI intents (send, interrupt,
/// allow, stop a task) into protocol messages.
final class ChatSession {
    typealias JSON = [String: Any]

    enum RunState: Equatable {
        case notStarted, running
        case needsTrust                 // the folder isn't trusted yet (see ChatTrust) — waiting on the user
        case exited(code: Int32, signal: Bool, message: String)
        case failed(String)             // couldn't launch at all (no `claude` on PATH, …)
    }

    let tabID: String
    let cwd: String
    private(set) var launchArgs: String // the tab's Claude args (flags like --dangerously-skip-permissions, --model)
    private(set) var claudeSessionId: String?
    /// A fork's source conversation: until this chat has its own id it launches `--resume <parent>
    /// --fork-session` (Claude gives the copy a new id on its first turn), showing the parent's history.
    private(set) var forkParentId: String?
    /// The fork's name, given to Claude (`rename_session`) once the fork has its own id — so the tab (and
    /// Claude's resume list) keep it instead of the copied conversation's title.
    private let forkTitle: String?

    weak var observer: ChatSessionObserver?

    // Transcript
    private(set) var items: [ChatItem] = []
    private var nextID = 1                        // live items count up
    private var nextHistoryID = 0                 // history loaded above counts down
    private var toolItems: [String: Int] = [:]    // tool_use id → item id
    private var orphanResults: [String: (String, Bool)] = [:]   // results whose call is in unloaded history
    private(set) var historyPath: String?
    private(set) var historyStart: UInt64?        // byte offset the loaded history starts at (0 = all loaded)
    private(set) var historyLoading = false
    private var historyBranch: ChatHistory.Branch = .find   // where the live branch continues above what's loaded

    // Streaming bookkeeping for the current assistant message
    private var currentMessageID: String?
    private var blockItems: [String: [Int?]] = [:] // message id → item id per content block (nil = not shown)
    private var assistantCursor: [String: Int] = [:]
    private var toolJSON: [Int: String] = [:]     // item id → partial tool-input JSON while it streams
    /// After a compaction Claude replays the messages it kept (already on screen) as un-streamed assistant
    /// events. Skip those; real new output always streams first (`message_start`), which ends the replay —
    /// so an auto-compaction mid-turn never hides what comes next.
    private var replayingAfterCompact = false
    /// Compactions the running process did itself. It still holds the full messages above those — /rewind
    /// can go back past them; a restarted (`--resume`d) process loads only what follows a compaction.
    private var liveCompactions = Set<Int>()

    // Run state
    private var stream: ClaudeStream?
    private(set) var runState: RunState = .notStarted
    private(set) var isWorking = false
    private(set) var turnStartedAt: Date?
    private(set) var activity: String?            // "Thinking", "Running Bash", …
    private(set) var thinkingTokens = 0
    /// A compaction under way: when it began, when Claude said it ended (the size arrives just after, on
    /// `compact_boundary`, which is when it's timed), and what past ones of its size took (`CompactTiming`).
    private var compactingSince: Date?, compactingEnded: Date?
    private(set) var compactEstimate: Int?
    private(set) var turnOutputTokens = 0
    private(set) var prompts: [ChatPrompt] = []   // pending can_use_tool requests; the first is shown
    /// Messages sent while Claude was busy. They wait here, not in Claude's own queue — Claude merges
    /// everything waiting there into one message when its next turn starts (whatever `priority` says), so
    /// three questions got one answer. Held here, each goes out when the turn before it ends
    /// (`sendNextQueued`) and gets its own. The cost: Claude can't fold a message into a turn still running
    /// (steering mid-task) — esc, then send.
    private var queued: [(text: String, uuid: String, images: [ChatAttachment])] = []
    /// `!` shell output goes to Claude as messages that don't ask the model (`shouldQuery: false`) — Claude
    /// still runs an empty turn for them (init → result). Those turns are silent: no "working", no "done".
    private var silentUUIDs = Set<String>()
    private var batchSilent = false, batchReal = false   // what the commands starting the next turn are
    private var turnSilent = false
    private var shellProcess: Process?
    var shellRunning: Bool { shellProcess != nil }
    /// `/btw` exchanges so far — sent along so a follow-up side question has the earlier ones.
    private var sideHistory: [(question: String, answer: String)] = []
    /// The newest user message this chat sent Claude (a prompt, or a `!` command's output). A rewind to an
    /// older message must name it (`last_seen_user_message_uuid`), or Claude refuses ("stale target"). Nil
    /// until this process sends something — then the newest id in the loaded history stands in.
    private var lastSentUUID: String?
    private var sideRequest: String?
    var queuedTexts: [String] { queued.map(\.text) }
    var prompt: ChatPrompt? { prompts.first }

    // Chrome
    private(set) var model: String?
    private(set) var permissionMode = "default"
    private(set) var contextUsed = 0
    private var reportedWindow: Int?
    var contextWindow: Int { reportedWindow ?? ModelName.contextWindow(model ?? "") }
    var contextPercent: Int { contextWindow > 0 ? min(100, Int((Double(contextUsed) / Double(contextWindow) * 100).rounded())) : 0 }
    /// Usage windows are account-wide, so a new tab starts from the last values any chat saw.
    private(set) var fiveHour: RateWindow? = ChatStore.shared.lastFiveHour
    private(set) var sevenDay: RateWindow? = ChatStore.shared.lastSevenDay
    private(set) var rateLimitNote: String?
    private(set) var tasks: [ChatTask] = []
    private(set) var commands: [ChatCommand] = []
    private(set) var models: [ChatModelOption] = []
    private(set) var totalCostUSD = 0.0
    private(set) var lastTurnSeconds: Double?

    private(set) var effort: String?             // effort level picked for this tab (nil = the model's default)
    private(set) var fastModeState: String?      // "on" / "off" as Claude reports it
    private(set) var fastModeReason: String?     // why it's unavailable ("extra_usage_disabled", …)
    private(set) var remoteURL: String?          // Remote Control session link while it's on

    /// The picked model's entry in Claude's model list (effort levels, fast/auto mode support).
    var currentModelOption: ChatModelOption? {
        models.first { $0.resolved == model } ?? models.first { $0.value == model }
    }

    /// Modes Shift-Tab cycles through, like the terminal UI: auto only where the model supports it, bypass
    /// always (every chat launches with `--allow-dangerously-skip-permissions`; switching into it asks once).
    var modeCycle: [String] {
        var m = ["default", "acceptEdits", "plan"]
        if currentModelOption?.supportsAutoMode == true { m.append("auto") }
        m.append("bypassPermissions")
        return m
    }

    init(tabID: String, cwd: String, args: String, claudeSessionId: String?, forkParentId: String? = nil,
         forkTitle: String? = nil) {
        self.tabID = tabID
        self.cwd = cwd
        self.launchArgs = args
        self.claudeSessionId = claudeSessionId
        self.forkParentId = claudeSessionId == nil ? forkParentId : nil
        self.forkTitle = self.forkParentId == nil ? nil : forkTitle
        let parts = Self.userArgs(args)
        if let i = parts.firstIndex(of: "--effort"), i + 1 < parts.count { effort = parts[i + 1] }
    }

    // MARK: - Lifecycle

    /// Launch `claude` (resuming this tab's conversation if it has one) and load its history from disk.
    func start() {
        guard runState != .running else { return }
        guard ChatTrust.isTrusted(cwd) else { runState = .needsTrust; notify(); return }
        let exe = Env.resolve("claude")
        guard exe.hasPrefix("/") else {
            runState = .failed("Claude Code isn’t installed or isn’t on your PATH (`claude` not found).")
            notify(); return
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        args += Self.userArgs(launchArgs)
        // Lets the mode menu / ⇧⇥ switch into bypass later without starting in it (the terminal UI's flag).
        if !args.contains("--dangerously-skip-permissions") { args.append("--allow-dangerously-skip-permissions") }
        if let cid = claudeSessionId ?? forkParentId {
            if let path = ClaudeTranscript.file(forSessionId: cid) {
                args += ["--resume", cid]
                if claudeSessionId == nil {
                    args.append("--fork-session")
                    if items.isEmpty { addNotice("Forked conversation — what you do here doesn’t change the original.") }
                }
                // Not over a conversation this tab already shows (a restart of a chat begun here) — that
                // would draw it twice, and /rewind would cut at the older copy.
                if historyPath == nil, !items.contains(where: { $0.uuid != nil }) { loadHistory(path: path) }
            } else if items.isEmpty {
                // Claude only saves a conversation once it has done some work; a very new one can't resume.
                addNotice(claudeSessionId == nil
                    ? "The conversation being forked isn’t saved on disk yet, so this chat starts a new one."
                    : "This conversation isn’t saved on disk yet, so the chat starts a new one.")
            }
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Env.loginPath
        // Markers of a *parent* Claude session (Multee launched from inside Claude Code) would make this
        // one behave as that session's child — e.g. transcript saving off. A chat is its own session.
        for k in Self.parentSessionEnv { env[k] = nil }
        // Print mode keeps file checkpoints (what /rewind restores code from) only when asked; the terminal
        // UI keeps them by default. `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING` still wins inside Claude.
        env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        // Same for the Artifact tool: off by default in print mode ("sdk_default_off" — measured, 2.1.280), on in
        // the terminal UI, so a conversation that made artifacts in a terminal tab lost them here. Your own
        // `CLAUDE_CODE_ARTIFACT` (e.g. 0) and Claude's own artifacts-off setting still win.
        if env["CLAUDE_CODE_ARTIFACT"] == nil { env["CLAUDE_CODE_ARTIFACT"] = "1" }
        let s = ClaudeStream(executable: exe, arguments: args, cwd: cwd, environment: env)
        s.onMessages = { [weak self, weak s] batch in
            guard let self, let s, self.stream === s else { return }
            batch.forEach { self.handle($0) }
            self.notify()
        }
        s.onExit = { [weak self, weak s] code, signaled, err in
            guard let self, let s, self.stream === s else { return }
            self.processEnded(code: code, signaled: signaled, stderr: err)
        }
        do { try s.start() } catch {
            runState = .failed("Couldn’t start Claude: \(error.localizedDescription)")
            notify(); return
        }
        stream = s
        runState = .running
        liveCompactions = []                // a new process reads compactions from the file, like any resume
        compactingSince = nil; compactingEnded = nil; compactEstimate = nil
        s.control("initialize") { [weak self] resp, _ in self?.applyInitialize(resp ?? [:]) }
        notify()
    }

    static let parentSessionEnv = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SSE_PORT"]

    /// The user trusted the folder from the chat's prompt → remember it and launch.
    func trustAndStart() {
        ChatTrust.remember(cwd)
        runState = .notStarted
        start()
    }

    /// The user's default args minus anything that fights the chat transport: print mode (we add it),
    /// continue/resume (a chat resumes only its *own* conversation).
    static func userArgs(_ raw: String) -> [String] {
        let drop: Set<String> = ["-p", "--print", "--continue", "-c", "--resume", "-r", "--fork-session"]
        return raw.split(separator: " ").map(String.init).filter { !drop.contains($0) }
    }

    /// `args` with `flag X` replaced by (or extended with) `value` — so a relaunch keeps a pick (model, effort).
    static func replacingFlag(_ flag: String, in args: String, with value: String) -> String {
        var parts = args.split(separator: " ").map(String.init)
        if let i = parts.firstIndex(of: flag) {
            if i + 1 < parts.count { parts[i + 1] = value } else { parts.append(value) }
        } else {
            parts += [flag, value]
        }
        return parts.joined(separator: " ")
    }

    /// Stop the process (tab closed / app quitting). Claude kills its background tasks on SIGTERM.
    func terminate() {
        shellProcess?.terminate()
        stream?.terminate()
        stream = nil
        if runState == .running { runState = .notStarted }
        isWorking = false
    }

    private func processEnded(code: Int32, signaled: Bool, stderr: String) {
        stream = nil
        silentUUIDs.removeAll(); batchSilent = false; batchReal = false; turnSilent = false
        sideRequest = nil
        let wasWorking = isWorking
        isWorking = false
        prompts.removeAll()
        activity = nil
        for i in items.indices where items[i].kind == .tool && (items[i].toolStatus == .running || items[i].toolStatus == .waiting) {
            items[i].toolStatus = .interrupted; bump(i)
        }
        for i in tasks.indices where tasks[i].isRunning { tasks[i].status = "stopped"; tasks[i].endedAt = Date() }
        let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
        runState = .exited(code: code, signal: signaled, message: tail)
        if !queued.isEmpty {
            addNotice("\(queued.count) queued message\(queued.count == 1 ? " was" : "s were") not sent: " +
                      queued.map { "“\($0.text)”" }.joined(separator: ", "), error: true)
            queued.removeAll()
        }
        if wasWorking { ChatStore.shared.onStatus?(tabID, .idle) }
        notify()
    }

    /// Relaunch after an exit, resuming the same conversation.
    func restart() {
        terminate()
        runState = .notStarted
        start()
    }

    // MARK: - User intents

    /// Send a message (or handle a chat-local command). Starts/restarts the process if it isn't running.
    func send(_ raw: String, images: [ChatAttachment] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if handleLocal(text) { return }
        if runState == .needsTrust { addNotice("Trust this folder first (the button above the message box)."); return }
        if runState != .running { runState = .notStarted; start() }
        guard let stream, runState == .running else { return }
        let uuid = UUID().uuidString.lowercased()
        ChatStore.shared.onPrompt?(tabID, text)
        if isWorking {
            queued.append((text, uuid, images))         // sent when this turn ends — see `sendNextQueued`
        } else {
            append(userItem(text, uuid: uuid, images: images))
            stream.sendUser(text, uuid: uuid, images: images)
            lastSentUUID = uuid
            beginTurn()
        }
        notify()
    }

    /// A turn ended: send the oldest message that waited for it, as a turn of its own.
    private func sendNextQueued() {
        guard !isWorking, runState == .running, let stream, !queued.isEmpty else { return }
        let q = queued.removeFirst()
        append(userItem(q.text, uuid: q.uuid, images: q.images))
        stream.sendUser(q.text, uuid: q.uuid, images: q.images)
        lastSentUUID = q.uuid
        beginTurn()
    }

    /// Commands the chat handles itself: `/model <name>` maps to the model switch; commands that need the
    /// terminal UI (pickers, editors) are explained instead of sent.
    private func handleLocal(_ text: String) -> Bool {
        if text.hasPrefix("!") {
            let command = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty { addNotice("Type a shell command after ! — e.g. `!git status`. Its output joins the conversation.") }
            else { runShell(command) }
            return true
        }
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        if name == "model", parts.count == 2 { setModel(parts[1].trimmingCharacters(in: .whitespaces)); return true }
        if name == "remote-control" || name == "rc" {
            let arg = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            setRemoteControl(!["off", "stop", "disable"].contains(arg.lowercased()), name: ["on", "off", "stop", "disable"].contains(arg.lowercased()) ? nil : arg)
            return true
        }
        if name == "resume", parts.count == 2 { switchConversation(to: parts[1].trimmingCharacters(in: .whitespaces)); return true }
        // Not offered by this Claude in print mode (its `initialize` command list decides, so a command a
        // newer Claude adds to print mode just works).
        if Self.terminalOnly.contains(name) && !commands.contains(where: { $0.name.lowercased() == name }) {
            addNotice("/\(name) needs Claude’s terminal UI — use “Open in Terminal” in the footer to continue this conversation there.")
            return true
        }
        if name == "exit" || name == "quit" { addNotice("Close the tab to end this chat (⌘W)."); return true }
        return false
    }

    /// Terminal-UI commands (pickers, editors). Only intercepted when Claude doesn't list them for this
    /// session — verified absent from print mode in 2.1.278: permissions, plugin, hooks, login, statusline,
    /// theme, vim.
    static let terminalOnly: Set<String> = ["permissions", "plugin", "plugins", "hooks", "login", "logout",
        "statusline", "theme", "vim", "terminal-setup", "ide", "doctor", "agents", "mcp", "model",
        "output-style", "tasks", "bashes"]

    /// Which commands are skills. `initialize` (at startup) flags Claude's commands `builtin`, but that covers the
    /// skills bundled with the CLI (claude-api, verify…) too; only the `init` event (with the first reply) lists
    /// the skills. So every chat's list is remembered — skills rarely change, and it's only ever matched against
    /// this chat's own commands — and a new chat knows them before its first message.
    private static let skillsKey = "multee.chatSkills"
    private(set) static var knownSkills = Set(UserDefaults.standard.stringArray(forKey: skillsKey) ?? [])

    private static func rememberSkills(_ names: [String]) {
        let all = knownSkills.union(names)
        guard all != knownSkills else { return }
        knownSkills = all
        UserDefaults.standard.set(all.sorted(), forKey: skillsKey)
    }

    private func markSkills() {
        for i in commands.indices where !commands[i].skill && Self.knownSkills.contains(commands[i].name) {
            commands[i].skill = true
        }
    }

    /// Commands the chat implements itself (print mode doesn't offer them) — merged into `/` completion.
    static let localCommands: [ChatCommand] = [
        ChatCommand(name: "rewind", description: "Go back to an earlier message — restore the code, the conversation, or both (esc esc)", hint: ""),
        ChatCommand(name: "fork", description: "Branch this conversation into a new chat tab", hint: "[name]"),
        ChatCommand(name: "copy", description: "Copy Claude’s last reply (or the n-th latest) to the clipboard", hint: "[n]"),
        ChatCommand(name: "export", description: "Save this conversation as a Markdown file", hint: "[file]"),
        ChatCommand(name: "memory", description: "Open a CLAUDE.md memory file in the editor", hint: ""),
        ChatCommand(name: "plan", description: "Switch to plan mode (and send a task), or open the current plan", hint: "[open|<task>]"),
        ChatCommand(name: "btw", description: "Ask a quick side question — the answer isn’t added to the conversation", hint: "<question>"),
        ChatCommand(name: "resume", description: "Resume another conversation in this tab", hint: "[id]"),
        ChatCommand(name: "remote-control", description: "Continue this session from claude.ai or the Claude app", hint: "[off]"),
        ChatCommand(name: "tasks", description: "Show background tasks", hint: ""),
    ]

    /// Take queued message `i` back to edit it (↑ in the box, as in the terminal UI). Claude hasn't seen it yet —
    /// it's still waiting here — so this just removes it.
    func retractQueued(_ i: Int) -> (text: String, images: [ChatAttachment])? {
        guard queued.indices.contains(i) else { return nil }
        let q = queued.remove(at: i)
        notify()
        return (q.text, q.images)
    }

    func interrupt() {
        guard isWorking || !prompts.isEmpty else { return }
        for p in prompts {
            stream?.respond(to: p.requestID, ["behavior": "deny", "message": "The user interrupted."])
            setToolStatus(p.toolUseID, .interrupted)
        }
        prompts.removeAll()
        stream?.control("interrupt")
        activity = "Interrupting"
        notify()
    }

    enum PromptAnswer {
        case allow, allowAlways, deny(String?)
        case answers([String: String])            // AskUserQuestion: question text → chosen label(s)
        case approvePlan(mode: String)            // ExitPlanMode: allow + switch mode (acceptEdits/default)
    }

    func answer(_ answer: PromptAnswer) {
        guard let p = prompts.first, let stream else { return }
        prompts.removeFirst()
        var response: JSON
        switch answer {
        case .allow:
            response = ["behavior": "allow", "updatedInput": p.input]
        case .allowAlways:
            response = ["behavior": "allow", "updatedInput": p.input]
            if !p.suggestions.isEmpty { response["updatedPermissions"] = p.suggestions }
            for s in p.suggestions where s["type"] as? String == "setMode" {
                if let m = s["mode"] as? String { permissionMode = m }
            }
        case .deny(let message):
            let m = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            response = ["behavior": "deny", "message": m.isEmpty ? "The user denied this." : m]
        case .answers(let answers):
            var input = p.input
            input["answers"] = answers
            response = ["behavior": "allow", "updatedInput": input]
        case .approvePlan(let mode):
            response = ["behavior": "allow", "updatedInput": p.input]
            stream.respond(to: p.requestID, response)
            setPermissionMode(mode)
            setToolStatus(p.toolUseID, .running)
            afterPrompt()
            return
        }
        stream.respond(to: p.requestID, response)
        if case .deny = answer { setToolStatus(p.toolUseID, .denied) } else { setToolStatus(p.toolUseID, .running) }
        afterPrompt()
    }

    private func afterPrompt() {
        if prompts.isEmpty { ChatStore.shared.onStatus?(tabID, isWorking ? .working : .idle) }
        notify()
    }

    func setPermissionMode(_ mode: String) {
        guard let stream else { permissionMode = mode; notify(); return }
        let previous = permissionMode
        permissionMode = mode
        notify()
        stream.control("set_permission_mode", ["mode": mode]) { [weak self] _, err in
            guard let self, let err else { return }
            self.permissionMode = previous
            self.addNotice("Couldn’t switch mode: \(err)", error: true)
            self.notify()
        }
    }

    /// The mode ⇧⇥ goes to next.
    var nextMode: String { mode(after: permissionMode) }

    func mode(after mode: String) -> String {
        let cycle = modeCycle
        let i = cycle.firstIndex(of: mode) ?? -1
        return cycle[(i + 1) % cycle.count]
    }

    func cycleMode() { setPermissionMode(nextMode) }

    func setModel(_ value: String) {
        guard let stream else { addNotice("Claude isn’t running."); return }
        stream.control("set_model", ["model": value]) { [weak self] _, err in
            guard let self else { return }
            if let err { self.addNotice("Couldn’t switch model: \(err)", error: true); self.notify(); return }
            let resolved = self.models.first(where: { $0.value == value })?.resolved ?? value
            self.model = resolved
            self.reportedWindow = nil
            self.launchArgs = Self.replacingFlag("--model", in: self.launchArgs, with: value)
            ChatStore.shared.onArgs?(self.tabID, self.launchArgs)
            self.addNotice("Model set to \(ModelName.display(resolved))")
            self.notify()
        }
    }

    /// Effort level (`low`…`max`) for this session — Claude's `apply_flag_settings`, kept on the tab's args
    /// (`--effort`) so a restart keeps it.
    func setEffort(_ level: String) {
        guard let stream else { addNotice("Claude isn’t running."); return }
        stream.control("apply_flag_settings", ["settings": ["effortLevel": level]]) { [weak self] _, err in
            guard let self else { return }
            if let err { self.addNotice("Couldn’t set effort: \(err)", error: true); self.notify(); return }
            self.effort = level
            self.launchArgs = Self.replacingFlag("--effort", in: self.launchArgs, with: level)
            ChatStore.shared.onArgs?(self.tabID, self.launchArgs)
            self.addNotice("Effort set to \(level)")
            self.notify()
        }
    }

    func setFastMode(_ on: Bool) {
        guard let stream else { addNotice("Claude isn’t running."); return }
        stream.control("apply_flag_settings", ["settings": ["fastMode": on]]) { [weak self] _, err in
            guard let self else { return }
            if let err { self.addNotice("Couldn’t change fast mode: \(err)", error: true); self.notify(); return }
            self.addNotice(on ? "Fast mode requested — it applies from the next message, if your plan allows it." : "Fast mode off")
            self.notify()
        }
    }

    /// Remote Control: connect this session to claude.ai so it can be followed and driven from the web or
    /// the mobile app (the terminal UI's `/remote-control`, which print mode doesn't offer as a command).
    func setRemoteControl(_ on: Bool, name: String? = nil) {
        guard let stream else { addNotice("Claude isn’t running."); return }
        var fields: JSON = ["enabled": on]
        if let name, !name.isEmpty { fields["name"] = name }
        stream.control("remote_control", fields) { [weak self] resp, err in
            guard let self else { return }
            if let err { self.addNotice("Remote Control: \(err)", error: true); self.notify(); return }
            if on {
                self.remoteURL = resp?["session_url"] as? String ?? resp?["connect_url"] as? String
                self.addNotice("Remote Control is on — continue this session from claude.ai or the Claude app: \(self.remoteURL ?? "(no link returned)")")
            } else {
                self.remoteURL = nil
                self.addNotice("Remote Control is off")
            }
            self.notify()
        }
    }

    /// Resume another conversation in this tab (the chat's `/resume`): stop this one, show the picked one's
    /// history, and relaunch with `--resume <id>`. The current conversation stays resumable from the picker.
    func switchConversation(to cid: String) {
        guard cid != claudeSessionId else { return }
        terminate()
        items.removeAll(); toolItems.removeAll(); orphanResults.removeAll()
        historyPath = nil; historyStart = nil; historyLoading = false
        blockItems.removeAll(); assistantCursor.removeAll(); toolJSON.removeAll()
        prompts.removeAll(); queued.removeAll(); tasks.removeAll()
        lastSentUUID = nil
        historyBranch = .find
        contextUsed = 0; totalCostUSD = 0; remoteURL = nil; activity = nil
        claudeSessionId = cid
        forkParentId = nil
        ChatStore.shared.onClaudeId?(tabID, cid)
        observer?.chatItemsReset()
        runState = .notStarted
        start()
    }

    // MARK: - Shell mode (!)

    /// `!command`: run it in your shell in this folder, show the output, and add both to the conversation
    /// the way the terminal UI does (`<bash-input>` / `<bash-stdout>` messages that don't ask the model), so
    /// Claude sees what you ran next time you write.
    func runShell(_ command: String) {
        guard shellProcess == nil else { addNotice("A shell command is still running — esc stops it."); return }
        if runState == .needsTrust { addNotice("Trust this folder first (the button above the message box)."); return }
        if runState != .running { runState = .notStarted; start() }
        var item = ChatItem(id: takeID(), kind: .tool)
        item.toolName = ChatItem.shellTool
        item.toolInput = ["command": command]
        append(item)
        let itemID = item.id
        shellProcess = ChatShell.run(command, cwd: cwd) { [weak self] result in
            self?.shellFinished(itemID: itemID, command: command, result)
        }
        if shellProcess == nil { setShellResult(itemID, "Couldn’t start your shell.", failed: true) }
        notify()
    }

    /// Esc while a `!` command runs: ^C, then a firmer stop if it ignores that.
    func stopShell() {
        guard let p = shellProcess else { return }
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
    }

    private func shellFinished(itemID: Int, command: String, _ r: ChatShell.Result) {
        shellProcess = nil
        let shown = [r.stdout, r.stderr, r.failureNote ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        setShellResult(itemID, shown.isEmpty ? "(no output)" : shown, failed: r.failureNote != nil)
        // Its row is gone when the tab switched conversation (/resume) or rewound past it — then the output
        // isn't this conversation's to get.
        guard index(of: itemID) != nil, let stream, runState == .running else { notify(); return }
        let input = UUID().uuidString.lowercased(), output = UUID().uuidString.lowercased()
        silentUUIDs.formUnion([input, output])
        lastSentUUID = output
        if let i = index(of: itemID) { items[i].uuid = output }      // its row is part of the conversation too
        stream.sendUser("<bash-input>\(command)</bash-input>", uuid: input, shouldQuery: false)
        let stderr = [r.stderr, r.failureNote ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        stream.sendUser("<bash-stdout>\(ChatShell.capped(r.stdout))</bash-stdout><bash-stderr>\(ChatShell.capped(stderr))</bash-stderr>",
                        uuid: output, shouldQuery: false)
        notify()
    }

    private func setShellResult(_ itemID: Int, _ text: String, failed: Bool) {
        guard let i = index(of: itemID) else { return }
        items[i].toolResult = text
        items[i].toolStatus = failed ? .failed : .done
        bump(i)
    }

    // MARK: - /btw, /plan

    /// A side question (`/btw`): Claude answers from this conversation's context without adding either to
    /// it, even while it's working on something else. `done` gets the answer or an error.
    func askSide(_ question: String, _ done: @escaping (_ answer: String?, _ error: String?) -> Void) {
        guard let stream, runState == .running else { done(nil, "Claude isn’t running."); return }
        cancelSide()
        let history = sideHistory.suffix(10).map { ["question": $0.question, "response": $0.answer] }
        sideRequest = stream.control("side_question", ["question": question, "history": history]) { [weak self] resp, err in
            guard let self else { return }
            self.sideRequest = nil
            if let err { done(nil, err); return }
            let answer = (resp?["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if answer.isEmpty { done(nil, "No answer came back — try again, or ask in the conversation."); return }
            self.sideHistory.append((question, answer))
            done(answer, nil)
        }
    }

    /// Drop a side question still waiting for its answer (the card was closed).
    func cancelSide() {
        if let id = sideRequest { stream?.cancelControl(id) }
        sideRequest = nil
    }

    /// The session's current plan (`get_plan`): its file, or nil when Claude hasn't written one.
    func fetchPlan(_ done: @escaping (_ path: String?, _ error: String?) -> Void) {
        guard let stream else { done(nil, "Claude isn’t running."); return }
        stream.control("get_plan") { resp, err in
            if let err { done(nil, err); return }
            done(resp?["exists"] as? Bool == true ? resp?["path"] as? String : nil, nil)
        }
    }

    /// What the activity line says while Claude compacts — the terminal UI's words. Print mode reports only the
    /// start and end of a compaction, no progress, so the line shows the elapsed time and, once past compactions
    /// of this size have been timed, what they usually took (`compactEstimate`).
    static let compactingActivity = "Compacting conversation"

    // MARK: - Rewind

    /// Messages /rewind can go back to, newest first: your own prompts that Claude has an id for, since the
    /// last compaction this process read from the file. Claude drops the messages above one of those, but not
    /// above a compaction it did itself while running (measured: `target_not_found` only after a restart).
    /// A slash command counts when Claude answered it (a skill, a custom command); a built-in one (`/model`,
    /// `/compact`) only leaves a notice, and going back to before it would undo nothing it did.
    var rewindTargets: [ChatItem] {
        let start = items.lastIndex { $0.compaction && !liveCompactions.contains($0.id) }.map { $0 + 1 } ?? 0
        return items.indices[start...].reversed().filter { i in
            items[i].kind == .user && items[i].uuid != nil && (!items[i].text.hasPrefix("/") || answered(i))
        }.map { items[$0] }
    }

    /// Whether the model replied to the user message at `i` — anything of its own before the next user message.
    /// A built-in command's output doesn't count: it arrives as a `<synthetic>` reply, and some of those
    /// commands (`/release-notes`) never reach the transcript, so a rewind to them finds nothing. Nor does a
    /// `!` shell row that follows — that's your command, not a reply.
    private func answered(_ i: Int) -> Bool {
        items[(i + 1)...].prefix { $0.kind != .user }.contains {
            switch $0.kind {
            case .assistant: return !$0.synthetic
            case .thinking: return true
            case .tool: return $0.toolName != ChatItem.shellTool
            case .user, .notice, .error: return false
            }
        }
    }

    struct FileChanges { let files: [String]; let insertions: Int; let deletions: Int }

    /// What restoring the code to just before message `uuid` would change (a `rewind_files` dry run) — or
    /// why it can't (no checkpoint for that message, e.g. one sent from an older Claude).
    func previewRewind(_ uuid: String, _ done: @escaping (_ changes: FileChanges?, _ unavailable: String?) -> Void) {
        guard let stream else { done(nil, "Claude isn’t running."); return }
        stream.control("rewind_files", ["user_message_id": uuid, "dry_run": true]) { resp, err in
            if let err { done(nil, err); return }
            guard let resp, resp["canRewind"] as? Bool == true else {
                done(nil, resp?["error"] as? String ?? "No code checkpoint for this message."); return
            }
            done(FileChanges(files: resp["filesChanged"] as? [String] ?? [], insertions: resp["insertions"] as? Int ?? 0,
                             deletions: resp["deletions"] as? Int ?? 0), nil)
        }
    }

    /// Go back to just before message `uuid` (the terminal UI's /rewind): restore the files Claude changed
    /// since then (`rewind_files`) and/or cut the conversation there (`rewind_conversation` — Claude drops
    /// the message and everything after it, in memory and in the transcript). `done` gets the message's
    /// text to put back in the box after a conversation rewind, nil otherwise.
    func rewind(to uuid: String, code: Bool, conversation: Bool, done: @escaping (String?) -> Void) {
        guard let stream else { addNotice("Claude isn’t running."); done(nil); return }
        guard !isWorking, prompts.isEmpty else {
            addNotice("Claude is working — press esc to stop it, then rewind."); done(nil); return
        }
        let original = items.first { $0.uuid == uuid }?.text ?? ""
        let quoted = "“\(original.split(separator: "\n").first.map { $0.count > 60 ? String($0.prefix(59)) + "…" : String($0) } ?? "")”"
        let finishConversation = { [weak self] in
            guard let self else { return }
            var fields: JSON = ["target_message_uuid": uuid]
            if let seen = self.lastSentUUID ?? self.items.last(where: { $0.uuid != nil })?.uuid {
                fields["last_seen_user_message_uuid"] = seen
            }
            stream.control("rewind_conversation", fields) { [weak self] resp, err in
                guard let self else { return }
                guard err == nil, let resp, resp["rewound"] as? Bool == true else {
                    let why = err ?? Self.rewindRefusal(resp?["reason"] as? String) ?? resp?["error"] as? String ?? "Claude refused."
                    self.addNotice("Couldn’t rewind the conversation: \(why)", error: true)
                    done(nil); return
                }
                self.truncate(at: uuid)
                self.addNotice(code ? "Rewound the conversation and code to before \(quoted)"
                                    : "Rewound the conversation to before \(quoted) — files are unchanged")
                self.fetchContextUsage { [weak self] r, _ in self?.applyContextUsage(r) }
                // Claude's prefill for a slash command is its `<command-name>` markup — put back what was typed.
                done(original.hasPrefix("/") ? original : resp["prefillText"] as? String ?? original)
            }
        }
        guard code else { finishConversation(); return }
        stream.control("rewind_files", ["user_message_id": uuid]) { [weak self] resp, err in
            guard let self else { return }
            if let why = err ?? (resp?["canRewind"] as? Bool == true ? nil : resp?["error"] as? String ?? "Claude refused.") {
                self.addNotice("Couldn’t restore the code: \(why)", error: true)
                done(nil); return
            }
            if conversation { finishConversation(); return }
            self.addNotice("Restored the code to before \(quoted) — the conversation is unchanged")
            done(nil)
        }
    }

    /// Claude's rewind refusal codes, in plain words.
    private static func rewindRefusal(_ reason: String?) -> String? {
        switch reason {
        case "target_not_found": return "Claude no longer has that message — it was compacted, or already rewound away."
        case "stale_target", "unseen_later_turn":
            return "Claude has newer messages than this chat shows (sent from claude.ai or another client?) — reopen the conversation, then rewind."
        case "turn_running", "commands_queued", "prompt_pending": return "Claude is busy — wait for it to finish (or press esc), then rewind."
        case "target_splits_tool_call", "poll_tool_result_target", "delivered_poll_events_in_range":
            return "that point is in the middle of a tool call — pick another message."
        case "persist_failed": return "Claude couldn’t save the rewind — try again."
        case "state_changed": return "the conversation changed while rewinding — try again."
        default: return nil
        }
    }

    /// Drop message `uuid` and everything after it (Claude already did, on its side).
    private func truncate(at uuid: String) {
        guard let i = items.firstIndex(where: { $0.uuid == uuid }) else { return }
        lastSentUUID = nil          // it may have been cut; the newest id left on screen stands in
        for item in items[i...] { if let t = item.toolUseID { toolItems[t] = nil } }
        items.removeSubrange(i...)
        blockItems.removeAll(); assistantCursor.removeAll(); toolJSON.removeAll(); currentMessageID = nil
        observer?.chatItemsTruncated()
    }

    func stopTask(_ id: String) {
        stream?.control("stop_task", ["task_id": id]) { [weak self] _, err in
            guard let self else { return }
            if let err { self.addNotice("Couldn’t stop task: \(err)", error: true) }
            self.notify()
        }
    }

    func clearFinishedTasks() {
        tasks.removeAll { !$0.isRunning }
        notify()
    }

    /// Detailed context breakdown (`get_context_usage`) for the footer's context popover.
    func fetchContextUsage(_ done: @escaping (JSON?, String?) -> Void) {
        guard let stream else { done(nil, "Claude isn’t running"); return }
        stream.control("get_context_usage", [:], completion: done)
    }

    /// Adopt Claude's own context count (`get_context_usage`): exact before the first turn, and after a
    /// compaction or model switch, where the last streamed usage would be stale.
    func applyContextUsage(_ r: JSON?) {
        guard let r, let total = r["totalTokens"] as? Int else { return }
        contextUsed = total
        if let max = (r["rawMaxTokens"] as? Int) ?? (r["maxTokens"] as? Int), max > 0 { reportedWindow = max }
        notify()
    }

    func toggleExpanded(itemID: Int) {
        guard let i = index(of: itemID) else { return }
        items[i].expanded.toggle()
        bump(i)
    }

    /// Ports found listening under a task's process (the footer's port scan) — main thread.
    func setPorts(_ ports: [String: [Int]]) {
        var changed = false
        for i in tasks.indices {
            let p = ports[tasks[i].id] ?? []
            if tasks[i].ports != p { tasks[i].ports = p; changed = true }
        }
        if changed { notify() }
    }

    var processID: Int32? { stream?.isRunning == true ? stream?.pid : nil }

    /// Running background shells with the command each runs (from its Bash call — the task's own
    /// description is Claude's summary, not the command), for attributing listening ports.
    var runningShells: [(id: String, command: String)] {
        tasks.filter { $0.isRunning && $0.isShell }.map { t in
            let cmd = t.toolUseID.flatMap { toolItems[$0] }.flatMap { index(of: $0) }
                .flatMap { items[$0].toolInput["command"] as? String } ?? t.description
            return (t.id, cmd)
        }
    }

    // MARK: - History

    private func loadHistory(path: String) {
        historyPath = path
        loadEarlier()
    }

    var canLoadEarlier: Bool { historyPath != nil && (historyStart ?? 1) > 0 && !historyLoading }

    /// Load the next chunk of history above what's shown (off-main; prepends on completion).
    func loadEarlier() {
        guard let path = historyPath, !historyLoading, historyStart != 0 else { return }
        historyLoading = true
        notify()
        let end = historyStart, branch = historyBranch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let chunk = ChatHistory.load(path: path, endOffset: end, branch: branch)
            DispatchQueue.main.async { self?.prependHistory(chunk, path: path) }
        }
    }

    /// Every item of the conversation — the loaded ones plus any history above them, read off-main without
    /// changing what's shown (for /export).
    func loadFullHistory(_ done: @escaping ([ChatItem]) -> Void) {
        let shown = items
        guard let path = historyPath, let startOffset = historyStart, startOffset > 0 else { done(shown); return }
        var orphans = orphanResults
        let branch0 = historyBranch
        DispatchQueue.global(qos: .userInitiated).async {
            var chunks: [[ChatItem]] = []
            var end = startOffset, branch = branch0
            while end > 0, let chunk = ChatHistory.load(path: path, endOffset: end, branch: branch), chunk.startOffset < end {
                var got = chunk.items
                for i in got.indices where got[i].kind == .tool {
                    if let id = got[i].toolUseID, let (result, isError) = orphans.removeValue(forKey: id) {
                        got[i].toolResult = result
                        got[i].toolStatus = isError ? .failed : .done
                    }
                }
                orphans.merge(chunk.results) { a, _ in a }
                chunks.append(got)
                end = chunk.startOffset
                branch = chunk.branch
            }
            let all = chunks.reversed().flatMap { $0 } + shown
            DispatchQueue.main.async { done(all) }
        }
    }

    private func prependHistory(_ chunk: ChatHistory.Chunk?, path: String) {
        guard path == historyPath else { return }      // a load for a conversation this tab switched away from
        historyLoading = false
        guard let chunk else { historyStart = 0; notify(); return }
        let progressed = chunk.startOffset < (historyStart ?? .max)
        historyStart = progressed ? chunk.startOffset : 0
        historyBranch = chunk.branch
        // A slice holding only undone (rewound) messages shows nothing — keep walking up to the live branch.
        if chunk.items.isEmpty, progressed, chunk.startOffset > 0 { loadEarlier(); return }
        // Results whose call we already hold (from a later chunk) came first; calls whose result we hold
        // (orphans from the later chunk) are resolved now.
        var fresh = chunk.items
        for i in fresh.indices where fresh[i].kind == .tool {
            if let id = fresh[i].toolUseID, let (result, isError) = orphanResults.removeValue(forKey: id) {
                fresh[i].toolResult = result
                fresh[i].toolStatus = isError ? .failed : .done
            }
        }
        orphanResults.merge(chunk.results) { a, _ in a }
        // Re-id downwards so ids stay sorted by position.
        var withIDs: [ChatItem] = []
        withIDs.reserveCapacity(fresh.count)
        var id = nextHistoryID - fresh.count + 1
        nextHistoryID -= fresh.count
        for item in fresh {
            withIDs.append(ChatItem(copying: item, id: id))
            id += 1
        }
        for item in withIDs { if let t = item.toolUseID { toolItems[t] = item.id } }
        items.insert(contentsOf: withIDs, at: 0)
        if !withIDs.isEmpty { observer?.chatItemsPrepended(withIDs.count) }
        notify()
    }

    // MARK: - Stream reducer

    private func handle(_ o: JSON) {
        switch o["type"] as? String {
        case "system": handleSystem(o)
        case "stream_event":
            guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
                  let e = o["event"] as? JSON else { return }
            handleStreamEvent(e)
        case "assistant":
            let mid = (o["message"] as? JSON)?["id"] as? String
            if replayingAfterCompact, mid == nil || blockItems[mid!] == nil { return }
            handleAssistant(o)
        case "user": handleUser(o)
        case "result": handleResult(o)
        case "rate_limit_event": handleRateLimit(o)
        case "control_request": handleControlRequest(o)
        case "command_lifecycle": handleLifecycle(o)
        case "control_cancel_request":
            // Claude withdrew a prompt (answered from Remote Control, or the turn ended) — drop its card.
            guard let rid = o["request_id"] as? String, let i = prompts.firstIndex(where: { $0.requestID == rid }) else { return }
            setToolStatus(prompts[i].toolUseID, .running)
            prompts.remove(at: i)
            ChatStore.shared.onStatus?(tabID, isWorking ? .working : .idle)
        default: break
        }
    }

    private func handleSystem(_ o: JSON) {
        switch o["subtype"] as? String {
        case "init":
            if let sid = o["session_id"] as? String, !sid.isEmpty, sid != claudeSessionId, sid != forkParentId {
                if forkParentId != nil, let forkTitle { stream?.control("rename_session", ["title": forkTitle]) }
                claudeSessionId = sid
                forkParentId = nil
                ChatStore.shared.onClaudeId?(tabID, sid)
            }
            if let m = o["model"] as? String { model = m }
            if let pm = o["permissionMode"] as? String { permissionMode = pm }
            if let f = o["fast_mode_state"] as? String { fastModeState = f; fastModeReason = o["fast_mode_disabled_reason"] as? String }
            if commands.isEmpty, let cmds = o["slash_commands"] as? [String] {
                commands = cmds.map { ChatCommand(name: $0, description: "", hint: "") }
            }
            if let sk = o["skills"] as? [String] { Self.rememberSkills(sk); markSkills() }
            turnSilent = batchSilent && !batchReal
            batchSilent = false; batchReal = false
            if !isWorking, !turnSilent { beginTurn() }
        case "status":
            if o["status"] as? String == "compacting" {
                if compactingSince == nil {         // Claude repeats the status every 30 s while it compacts
                    compactingSince = Date(); compactingEnded = nil
                    compactEstimate = CompactTiming.estimate(tokens: contextUsed, model: model ?? "", from: CompactTiming.load())
                }
            } else if compactingSince != nil, compactingEnded == nil {
                compactingEnded = Date()
                compactEstimate = nil
            }
            if let s = o["status"] as? String {
                activity = s == "requesting" ? (activity ?? "Thinking") : s == "compacting" ? Self.compactingActivity : s.capitalized
            } else if activity == Self.compactingActivity { activity = "Thinking" }
        case "compact_boundary":
            let meta = o["compact_metadata"] as? JSON
            if let since = compactingSince, let pre = meta?["pre_tokens"] as? Int {
                let secs = (compactingEnded ?? Date()).timeIntervalSince(since)
                CompactTiming.record(.init(model: model ?? "", tokens: pre, seconds: secs))
            }
            compactingSince = nil; compactingEnded = nil; compactEstimate = nil
            if let pre = meta?["pre_tokens"] as? Int, let post = meta?["post_tokens"] as? Int {
                addNotice("Conversation compacted (\(ChatActivityBar.compact(pre)) → \(ChatActivityBar.compact(post)) tokens)")
                contextUsed = post
            } else {
                addNotice("Conversation compacted")
            }
            items[items.count - 1].compaction = true
            liveCompactions.insert(items[items.count - 1].id)
            replayingAfterCompact = true
        case "thinking_tokens":
            thinkingTokens = o["estimated_tokens"] as? Int ?? thinkingTokens
        case "background_tasks_changed":
            let live = (o["tasks"] as? [JSON] ?? []).compactMap { $0["task_id"] as? String }
            for t in (o["tasks"] as? [JSON] ?? []) {
                guard let id = t["task_id"] as? String else { continue }
                upsertTask(id) { task in
                    task.type = t["task_type"] as? String ?? task.type
                    if let d = t["description"] as? String { task.description = d }
                }
            }
            for i in tasks.indices where tasks[i].isRunning && !live.contains(tasks[i].id) {
                tasks[i].status = "completed"; tasks[i].endedAt = tasks[i].endedAt ?? Date()
            }
        case "task_started":
            guard let id = o["task_id"] as? String else { return }
            upsertTask(id) { task in
                task.type = o["task_type"] as? String ?? task.type
                if let d = o["description"] as? String { task.description = d }
                task.toolUseID = o["tool_use_id"] as? String
                task.status = "running"
            }
        case "task_progress":
            guard let id = o["task_id"] as? String else { return }
            upsertTask(id) { task in task.activity = o["description"] as? String }
        case "task_updated":
            guard let id = o["task_id"] as? String, let patch = o["patch"] as? JSON else { return }
            upsertTask(id) { task in
                if let st = patch["status"] as? String { task.status = st }
                if let end = patch["end_time"] as? Double { task.endedAt = Date(timeIntervalSince1970: end / 1000) }
            }
        case "task_notification":
            guard let id = o["task_id"] as? String else { return }
            upsertTask(id) { task in
                if let st = o["status"] as? String { task.status = st }
                if let f = o["output_file"] as? String { task.outputFile = f }
                if task.endedAt == nil, !task.isRunning { task.endedAt = Date() }
            }
            // The terminal UI prints a line when a background task ends; so do we (an agent's summary is its
            // whole answer, so name it instead).
            if let t = tasks.first(where: { $0.id == id }) {
                let summary = (o["summary"] as? String)?.split(separator: "\n").first.map(String.init)
                let line = t.type == "local_agent" || summary == nil
                    ? "\(t.type == "local_agent" ? "Agent" : "Background task") “\(t.description)” \(t.status)"
                    : summary!
                addNotice(line.count > 200 ? String(line.prefix(199)) + "…" : line, error: t.status == "failed")
            }
        case "permission_denied":
            if let tool = o["tool_name"] as? String { addNotice("Permission denied: \(tool)") }
        default:
            break
        }
    }

    private func upsertTask(_ id: String, _ update: (inout ChatTask) -> Void) {
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            update(&tasks[i])
        } else {
            var t = ChatTask(id: id, type: "", description: "")
            update(&t)
            tasks.append(t)
        }
    }

    private func handleStreamEvent(_ e: JSON) {
        switch e["type"] as? String {
        case "message_start":
            replayingAfterCompact = false
            let msg = e["message"] as? JSON ?? [:]
            currentMessageID = msg["id"] as? String
            if let usage = msg["usage"] as? JSON { applyUsage(usage) }
        case "content_block_start":
            guard let mid = currentMessageID, let block = e["content_block"] as? JSON else { return }
            var slot: Int? = nil
            switch block["type"] as? String {
            case "text":
                var item = ChatItem(id: takeID(), kind: .assistant)
                item.streaming = true
                append(item); slot = item.id
                activity = "Writing"
            case "tool_use":
                var item = ChatItem(id: takeID(), kind: .tool)
                item.toolName = block["name"] as? String ?? "Tool"
                item.toolUseID = block["id"] as? String
                item.streaming = true
                if let t = item.toolUseID { toolItems[t] = item.id }
                append(item); slot = item.id
                activity = "Running \(ChatRender.toolTitle(item.toolName))"
            case "thinking", "redacted_thinking":
                activity = "Thinking"          // content is usually redacted; shown as the activity line
            default: break
            }
            blockItems[mid, default: []].append(slot)
        case "content_block_delta":
            guard let mid = currentMessageID, let idx = e["index"] as? Int,
                  let slots = blockItems[mid], idx < slots.count, let itemID = slots[idx],
                  let i = index(of: itemID), let delta = e["delta"] as? JSON else { return }
            switch delta["type"] as? String {
            case "text_delta":
                items[i].text += delta["text"] as? String ?? ""
                turnOutputTokens += 1
                bump(i)
            case "input_json_delta":
                toolJSON[itemID, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        case "content_block_stop":
            guard let mid = currentMessageID, let idx = e["index"] as? Int,
                  let slots = blockItems[mid], idx < slots.count, let itemID = slots[idx],
                  let i = index(of: itemID) else { return }
            if items[i].kind == .tool, items[i].toolInput.isEmpty, let json = toolJSON[itemID],
               let data = json.data(using: .utf8), let input = (try? JSONSerialization.jsonObject(with: data)) as? JSON {
                items[i].toolInput = input
            }
            toolJSON[itemID] = nil
            items[i].streaming = false
            bump(i)
        default:
            break
        }
    }

    /// A finished content block. Stream events already created its row; this makes it authoritative (full
    /// text, parsed tool input). Blocks arrive in order, so the k-th assistant event of a message is its
    /// k-th streamed block. Without stream events (a subagent, a synthetic reply) it creates the row.
    private func handleAssistant(_ o: JSON) {
        guard let msg = o["message"] as? JSON else { return }
        let content = ChatHistory.blocks(msg["content"])
        if let parent = o["parent_tool_use_id"] as? String {
            noteSubagent(parent: parent, content: content)
            return
        }
        let mid = msg["id"] as? String ?? UUID().uuidString
        var cursor = assistantCursor[mid] ?? 0
        for block in content {
            let slots = blockItems[mid] ?? []
            let existing: Int? = cursor < slots.count ? slots[cursor] : nil
            cursor += 1
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                if let id = existing, let i = index(of: id) {
                    items[i].text = text; items[i].streaming = false; bump(i)
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          text != "No response requested." {
                    var item = ChatItem(id: takeID(), kind: .assistant, text: text)
                    item.synthetic = msg["model"] as? String == "<synthetic>"
                    append(item)
                }
            case "tool_use":
                let input = block["input"] as? JSON ?? [:]
                if let id = existing, let i = index(of: id) {
                    items[i].toolInput = input; items[i].streaming = false; bump(i)
                } else {
                    var item = ChatItem(id: takeID(), kind: .tool)
                    item.toolName = block["name"] as? String ?? "Tool"
                    item.toolUseID = block["id"] as? String
                    item.toolInput = input
                    if let t = item.toolUseID { toolItems[t] = item.id }
                    append(item)
                }
            case "thinking":
                let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if existing == nil, !text.isEmpty { append(ChatItem(id: takeID(), kind: .thinking, text: text)) }
            default:
                break
            }
        }
        assistantCursor[mid] = cursor
    }

    /// Subagent traffic is summarized on its Agent/Task row (step count + latest action), not listed.
    private func noteSubagent(parent: String, content: [JSON]) {
        guard let id = toolItems[parent], let i = index(of: id) else { return }
        for block in content where block["type"] as? String == "tool_use" {
            items[i].subagentSteps += 1
            let name = block["name"] as? String ?? "Tool"
            let summary = ChatRender.toolSummary(name, block["input"] as? JSON ?? [:])
            items[i].subagentLast = ChatRender.toolTitle(name) + (summary.isEmpty ? "" : "(\(summary))")
        }
        bump(i)
    }

    private func handleUser(_ o: JSON) {
        guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
              let msg = o["message"] as? JSON else { return }
        for block in ChatHistory.blocks(msg["content"]) where block["type"] as? String == "tool_result" {
            guard let tid = block["tool_use_id"] as? String, let id = toolItems[tid], let i = index(of: id) else { continue }
            let result = ChatHistory.toolResultText(block["content"])
            let isError = block["is_error"] as? Bool ?? false
            items[i].toolResult = result
            if isError {
                let prior = items[i].toolStatus
                items[i].toolStatus = prior == .denied || prior == .interrupted ? prior : result.contains("denied") ? .denied : .failed
            } else {
                items[i].toolStatus = .done
            }
            items[i].streaming = false
            attachOutputFile(from: result, toolUseID: tid)
            bump(i)
        }
    }

    /// A backgrounded shell's result names its log file ("Output is being written to: …/x.output").
    private func attachOutputFile(from result: String, toolUseID: String) {
        guard result.contains(".output"),
              let r = result.range(of: #"(/[^\s]+\.output)"#, options: .regularExpression) else { return }
        let path = String(result[r])
        if let i = tasks.firstIndex(where: { $0.toolUseID == toolUseID }) { tasks[i].outputFile = path }
        else if let bgID = result.range(of: #"ID: ([A-Za-z0-9]+)"#, options: .regularExpression) {
            let id = String(result[bgID].dropFirst(4))
            upsertTask(id) { t in t.outputFile = path; t.toolUseID = toolUseID; if t.type.isEmpty { t.type = "local_bash" } }
        }
    }

    private func handleResult(_ o: JSON) {
        compactingSince = nil; compactingEnded = nil; compactEstimate = nil   // stopped, or failed: nothing to time
        if turnSilent { turnSilent = false; return }     // shell output joined the conversation — nothing ran
        let subtype = o["subtype"] as? String ?? ""
        if let cost = o["total_cost_usd"] as? Double { totalCostUSD = cost }
        if let ms = o["duration_ms"] as? Double { lastTurnSeconds = ms / 1000 }
        if let usage = o["modelUsage"] as? JSON, let m = model, let mu = usage[m] as? JSON,
           let w = mu["contextWindow"] as? Int, w > 0 { reportedWindow = w }
        if subtype == "error_during_execution" {
            addNotice("Interrupted")
        } else if o["is_error"] as? Bool == true {
            let msg = (o["result"] as? String) ?? (o["errors"] as? [String])?.joined(separator: "\n") ?? "Claude reported an error (\(subtype))."
            addNotice(msg, error: true)
        }
        for i in items.indices where items[i].kind == .tool && items[i].toolStatus == .running && !items[i].streaming
            && subtype == "error_during_execution" {
            items[i].toolStatus = .interrupted; bump(i)
        }
        for i in items.indices where items[i].streaming { items[i].streaming = false; bump(i) }
        isWorking = false
        activity = nil
        turnStartedAt = nil
        replayingAfterCompact = false
        blockItems.removeAll(); assistantCursor.removeAll(); toolJSON.removeAll()
        // The next queued message goes straight out (an interrupted turn's too — the terminal UI keeps its queue
        // past esc); only a turn with nothing after it is "idle", so no "done" notice fires in between.
        if queued.isEmpty || runState != .running { ChatStore.shared.onStatus?(tabID, .idle) } else { sendNextQueued() }
    }

    private func handleRateLimit(_ o: JSON) {
        guard let info = o["rate_limit_info"] as? JSON else { return }
        if let w = info["unifiedWindows"] as? JSON {
            fiveHour = Self.window(w["five_hour"]) ?? fiveHour
            sevenDay = Self.window(w["seven_day"]) ?? sevenDay
            ChatStore.shared.lastFiveHour = fiveHour
            ChatStore.shared.lastSevenDay = sevenDay
        }
        if info["status"] as? String == "rejected" {
            let reset = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let when = reset.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "later"
            let note = "Usage limit reached — resets at \(when)"
            if note != rateLimitNote { addNotice(note, error: true) }
            rateLimitNote = note
        } else {
            rateLimitNote = nil
        }
    }

    private static func window(_ any: Any?) -> RateWindow? {
        guard let w = any as? JSON, let u = w["utilization"] as? Double else { return nil }
        let reset = (w["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        return RateWindow(utilization: u, resetsAt: reset)
    }

    private func handleControlRequest(_ o: JSON) {
        guard let rid = o["request_id"] as? String, let req = o["request"] as? JSON else { return }
        guard req["subtype"] as? String == "can_use_tool" else {
            stream?.respondError(to: rid, "Unsupported request")
            return
        }
        let p = ChatPrompt(requestID: rid,
                           toolName: req["tool_name"] as? String ?? "Tool",
                           input: req["input"] as? JSON ?? [:],
                           toolUseID: req["tool_use_id"] as? String,
                           suggestions: req["permission_suggestions"] as? [JSON] ?? [],
                           reason: req["decision_reason"] as? String)
        prompts.append(p)
        setToolStatus(p.toolUseID, .waiting)
        ChatStore.shared.onStatus?(tabID, .needs)
    }

    private func applyUsage(_ u: JSON) {
        let total = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            + (u["cache_read_input_tokens"] as? Int ?? 0)
        if total > 0 { contextUsed = total }
    }

    private func applyInitialize(_ r: JSON) {
        if let cmds = r["commands"] as? [JSON] {
            commands = cmds.compactMap { c in
                guard let n = c["name"] as? String else { return nil }
                return ChatCommand(name: n, description: c["description"] as? String ?? "", hint: c["argumentHint"] as? String ?? "",
                                   skill: c["builtin"] as? Bool != true)
            }
            markSkills()
        }
        if let ms = r["models"] as? [JSON] {
            models = ms.compactMap { m in
                guard let v = m["value"] as? String else { return nil }
                var o = ChatModelOption(value: v, displayName: m["displayName"] as? String ?? v,
                                        description: m["description"] as? String ?? "",
                                        resolved: m["resolvedModel"] as? String ?? v)
                if m["supportsEffort"] as? Bool == true { o.effortLevels = m["supportedEffortLevels"] as? [String] ?? [] }
                o.supportsFastMode = m["supportsFastMode"] as? Bool ?? false
                o.supportsAutoMode = m["supportsAutoMode"] as? Bool ?? false
                return o
            }
        }
        if let pm = r["current_permission_mode"] as? String { permissionMode = pm }
        fastModeState = r["fast_mode_state"] as? String ?? fastModeState
        fastModeReason = r["fast_mode_disabled_reason"] as? String
        if model == nil {
            let args = Self.userArgs(launchArgs)
            if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
                let v = args[i + 1]
                model = models.first(where: { $0.value == v })?.resolved ?? v
            } else {
                model = models.first(where: { $0.value == "default" })?.resolved
            }
        }
        notify()
    }

    // MARK: - Helpers

    private func beginTurn() {
        isWorking = true
        turnStartedAt = Date()
        thinkingTokens = 0
        turnOutputTokens = 0
        activity = "Thinking"
        ChatStore.shared.onStatus?(tabID, prompts.isEmpty ? .working : .needs)
    }

    /// Which messages a turn is starting on (`command_lifecycle` "started"): a `!` command's output alone makes
    /// a silent turn. Queued prompts never reach Claude's own queue — see `queued`.
    private func handleLifecycle(_ o: JSON) {
        guard o["state"] as? String == "started", let cu = o["command_uuid"] as? String else { return }
        if silentUUIDs.remove(cu) != nil { batchSilent = true; return }
        batchReal = true
    }

    private func setToolStatus(_ toolUseID: String?, _ status: ChatItem.ToolStatus) {
        guard let t = toolUseID, let id = toolItems[t], let i = index(of: id) else { return }
        if items[i].toolStatus != status { items[i].toolStatus = status; bump(i) }
    }

    private func userItem(_ text: String, uuid: String, images: [ChatAttachment] = []) -> ChatItem {
        var item = ChatItem(id: takeID(), kind: .user, text: text)
        item.uuid = uuid
        item.images = images.compactMap(\.thumbnail)
        return item
    }

    func addNotice(_ text: String, error: Bool = false) {
        append(ChatItem(id: takeID(), kind: error ? .error : .notice, text: text))
        notify()
    }

    private func takeID() -> Int { defer { nextID += 1 }; return nextID }

    private func append(_ item: ChatItem) {
        items.append(item)
        observer?.chatItemsAppended((items.count - 1)..<items.count)
    }

    private func bump(_ i: Int) {
        items[i].version += 1
        observer?.chatItemChanged(at: i)
    }

    func index(of id: Int) -> Int? {
        var lo = 0, hi = items.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if items[mid].id == id { return mid }
            if items[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func notify() { observer?.chatStateChanged() }
}

extension ChatItem {
    /// The same item under a new id (history is re-id'd as it's prepended).
    init(copying o: ChatItem, id: Int) {
        self.init(id: id, kind: o.kind, text: o.text)
        uuid = o.uuid; compaction = o.compaction; synthetic = o.synthetic
        toolName = o.toolName; toolUseID = o.toolUseID; toolInput = o.toolInput
        toolResult = o.toolResult; toolStatus = o.toolStatus
        subagentSteps = o.subagentSteps; subagentLast = o.subagentLast
        expanded = o.expanded; images = o.images
    }
}

/// Every chat tab's session, keyed by tab id — the chat counterpart of `TerminalStore`. Sessions outlive
/// their view (a hidden tab keeps its process running) and die with the tab.
final class ChatStore {
    static let shared = ChatStore()
    private var sessions: [String: ChatSession] = [:]

    /// Status / conversation id / first prompt → the same routing Claude-tab hooks use (wired by AppDelegate):
    /// the tab's status dot, "done" attention + notifications, `--resume` id capture, tab naming.
    var onStatus: ((String, ClaudeState) -> Void)?
    var onClaudeId: ((String, String) -> Void)?
    var onPrompt: ((String, String) -> Void)?
    /// The tab's launch args changed (a model picked in the chat) → persist on the tab so a restart keeps it.
    var onArgs: ((String, String) -> Void)?
    /// Last usage windows seen by any chat (account-wide), kept across launches so a new tab shows them
    /// before its first turn. Expired windows are dropped.
    var lastFiveHour: RateWindow? {
        get { Self.loadWindow("chat.rate.5h") }
        set { Self.saveWindow(newValue, "chat.rate.5h") }
    }
    var lastSevenDay: RateWindow? {
        get { Self.loadWindow("chat.rate.7d") }
        set { Self.saveWindow(newValue, "chat.rate.7d") }
    }
    private static func loadWindow(_ key: String) -> RateWindow? {
        guard let d = UserDefaults.standard.dictionary(forKey: key), let u = d["u"] as? Double, let r = d["r"] as? Double,
              r > Date().timeIntervalSince1970 else { return nil }
        return RateWindow(utilization: u, resetsAt: Date(timeIntervalSince1970: r))
    }
    private static func saveWindow(_ w: RateWindow?, _ key: String) {
        guard let w else { return }
        UserDefaults.standard.set(["u": w.utilization, "r": w.resetsAt.timeIntervalSince1970], forKey: key)
    }

    func session(for tab: Tab, cwd: String, args: String) -> ChatSession {
        if let s = sessions[tab.id] { return s }
        let s = ChatSession(tabID: tab.id, cwd: cwd, args: args, claudeSessionId: tab.claudeSessionId,
                            forkParentId: tab.forkParentId, forkTitle: tab.title)
        sessions[tab.id] = s
        return s
    }

    func existing(_ tabID: String) -> ChatSession? { sessions[tabID] }

    func close(_ tabID: String) {
        sessions.removeValue(forKey: tabID)?.terminate()
    }

    func terminateAll() {
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
    }

    var all: [ChatSession] { Array(sessions.values) }
}
