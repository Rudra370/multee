import Foundation

/// One `claude -p` process speaking **stream-json** over stdin/stdout — the transport behind a chat tab.
/// Newline-delimited JSON both ways: we write `user` messages and `control_request`s (interrupt, set model,
/// stop a background task…); Claude writes stream events, messages, results, and its own `control_request`s
/// (tool-permission prompts) that we answer with a `control_response`.
///
/// Reading and JSON parsing happen off the main thread; each chunk's parsed messages are delivered to
/// `onMessages` on main in one hop. Writes go through a serial queue so a large paste can never block main
/// on a full pipe. Exit is reported only after stdout has fully drained, so no trailing message is lost.
final class ClaudeStream {
    typealias JSON = [String: Any]

    /// Parsed messages, in order, on the main thread.
    var onMessages: (([JSON]) -> Void)?
    /// The process ended (exit code — or the signal number when `signaled` — and the last stderr lines), on
    /// the main thread. Fires once.
    var onExit: ((_ code: Int32, _ signaled: Bool, _ stderr: String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.multee.chat.write")
    private var lineBuffer = Data()            // stdout bytes not yet terminated by a newline (read queue only)
    private var stderrTail = Data()            // last few KB of stderr, for the exit banner (guarded by lock)
    private let lock = NSLock()
    private var pendingControl: [String: (JSON?, String?) -> Void] = [:]   // request_id → completion (main only)
    private var nextRequestID = 0
    private let exitGroup = DispatchGroup()    // stdout EOF + process termination → report exit once

    private(set) var isRunning = false
    var pid: Int32 { process.processIdentifier }

    /// `SIGPIPE` would kill the whole app if Claude dies while we're writing to its stdin. Ignore it once;
    /// the write then just fails with EPIPE, which we swallow (the exit handler reports the death).
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(executable: String, arguments: [String], cwd: String, environment: [String: String]) {
        _ = Self.ignoreSigpipe
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        exitGroup.enter()   // stdout EOF
        exitGroup.enter()   // process termination
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {                               // EOF
                h.readabilityHandler = nil
                self.flushLines(final: true)
                self.exitGroup.leave()
                return
            }
            self.lineBuffer.append(data)
            self.flushLines(final: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8192 { self.stderrTail = self.stderrTail.suffix(4096) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.exitGroup.leave() }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        isRunning = true
        exitGroup.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.lock.lock()
            let err = String(decoding: self.stderrTail, as: UTF8.self)
            self.lock.unlock()
            // Fail any control request still waiting on an answer — the process can't send one now.
            let waiting = self.pendingControl
            self.pendingControl = [:]
            waiting.values.forEach { $0(nil, "Claude exited") }
            self.onExit?(self.process.terminationStatus, self.process.terminationReason == .uncaughtSignal,
                         err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Split complete lines out of `lineBuffer`, parse them, and hand the batch to main. Runs on the pipe's
    /// read queue (serial per handle), so `lineBuffer` needs no lock.
    private func flushLines(final: Bool) {
        var parsed: [JSON] = []
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if let obj = Self.parse(line) { parsed.append(obj) }
        }
        if final, !lineBuffer.isEmpty {
            if let obj = Self.parse(lineBuffer) { parsed.append(obj) }
            lineBuffer.removeAll()
        }
        guard !parsed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.deliver(parsed) }
    }

    private static func parse(_ line: Data) -> JSON? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? JSON
    }

    /// Main thread: resolve our own control requests' responses, pass everything else on.
    private func deliver(_ batch: [JSON]) {
        var rest: [JSON] = []
        for obj in batch {
            if obj["type"] as? String == "control_response",
               let resp = obj["response"] as? JSON, let id = resp["request_id"] as? String,
               let done = pendingControl.removeValue(forKey: id) {
                if resp["subtype"] as? String == "error" {
                    done(nil, resp["error"] as? String ?? "Request failed")
                } else {
                    done(resp["response"] as? JSON ?? [:], nil)
                }
                continue
            }
            rest.append(obj)
        }
        if !rest.isEmpty { onMessages?(rest) }
    }

    // MARK: - Writing

    func send(_ obj: JSON) {
        guard isRunning, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { try? handle.write(contentsOf: data) }   // EPIPE after a crash → ignored
    }

    /// A user turn. Text goes as a content block, exactly as the SDK sends it. Claude keeps `uuid` as the
    /// message's id in its transcript, so the chat can name the message later (`rewind_conversation`).
    /// `shouldQuery: false` adds the message to the conversation without asking the model (`!` shell output).
    func sendUser(_ text: String, uuid: String, shouldQuery: Bool = true, images: [ChatAttachment] = []) {
        var content: [JSON] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        var msg: JSON = ["type": "user",
                         "message": ["role": "user", "content": content],
                         "parent_tool_use_id": NSNull(), "session_id": "", "uuid": uuid]
        if !shouldQuery { msg["shouldQuery"] = false }
        send(msg)
    }

    /// Ask Claude to do something out-of-band (`interrupt`, `set_model`, `set_permission_mode`, `stop_task`,
    /// `get_context_usage`, `initialize`). The completion gets the response payload or an error string.
    /// Returns the request id (for `cancelControl`).
    @discardableResult
    func control(_ subtype: String, _ fields: JSON = [:], completion: ((JSON?, String?) -> Void)? = nil) -> String {
        nextRequestID += 1
        let id = "multee-\(nextRequestID)"
        var request = fields
        request["subtype"] = subtype
        if let completion { pendingControl[id] = completion }
        send(["type": "control_request", "request_id": id, "request": request])
        return id
    }

    /// Withdraw a request still in flight (a side question dismissed before its answer); its completion
    /// never fires.
    func cancelControl(_ id: String) {
        guard pendingControl.removeValue(forKey: id) != nil else { return }
        send(["type": "control_cancel_request", "request_id": id])
    }

    /// Answer one of Claude's control requests (a tool-permission prompt).
    func respond(to requestID: String, _ response: JSON) {
        send(["type": "control_response",
              "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    /// Refuse a control request we don't implement, so Claude doesn't wait on it forever.
    func respondError(to requestID: String, _ message: String) {
        send(["type": "control_response",
              "response": ["subtype": "error", "request_id": requestID, "error": message]])
    }

    /// Stop the process. SIGTERM lets Claude clean up — it kills the background tasks it started (a dev
    /// server, a watcher), which is what closing a chat tab should do.
    func terminate() {
        guard isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
    }
}
