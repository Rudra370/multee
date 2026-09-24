import AppKit
import AVFoundation

/// Voice input for the chat box — Claude Code's own speech-to-text, not Apple's. The terminal UI streams the mic
/// to `wss://api.anthropic.com/api/ws/speech_to_text/voice_stream` with the claude.ai login token; `claude -p`
/// has no voice, so the chat speaks that protocol itself (read from the CLI's bundled code, D43):
/// - query: `encoding=linear16&sample_rate=16000&channels=1&endpointing_ms=300&utterance_end_ms=1000&language=…
///   &use_conversation_engine=true`; headers `Authorization: Bearer <token>`, `User-Agent: claude-cli/<ver> …`,
///   `x-app: cli`, `anthropic-client-platform: claude_code_cli`.
/// - up: raw 16 kHz mono Int16 frames, `{"type":"KeepAlive"}` every 8 s, `{"type":"CloseStream"}` to finish.
/// - down: `TranscriptText` (the text so far, whole — with the conversation engine that's everything since the
///   start), `TranscriptEndpoint` (that text is final — in practice only after `CloseStream`; a `TranscriptText`
///   after one would start afresh), `TranscriptError` / `error`. The CLI assembles it the same way.
/// It is a private endpoint: if it changes, this breaks while the terminal UI's voice keeps working.
///
/// One recording at a time (there is one mic): starting one stops any other.
final class ChatVoice {
    enum State: String { case idle, connecting, recording, finishing }

    /// The whole transcript so far (finished utterances + the one in progress), on main.
    var onText: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }
    private(set) var lastError: String?
    /// What the harness feeds in place of the mic (16 kHz mono Int16), paced in real time — for the next
    /// recording only.
    var debugAudio: Data?
    private var fileAudio: Data?
    /// Milestones of the last recording, seconds from its start (harness: where the time goes).
    private(set) var timeline: [String] = []
    private var startedAt = Date()
    private func mark(_ what: String) { timeline.append(String(format: "%@ %.2f", what, Date().timeIntervalSince(startedAt))) }

    private static weak var active: ChatVoice?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var engine: AVAudioEngine?
    private var keepAlive: Timer?
    private var noDataTimer: DispatchWorkItem?     // after CloseStream: nothing more is coming
    private var safetyTimer: DispatchWorkItem?     // after stop: give up waiting altogether
    private var closeWhenOpen = false               // stopped while the socket was still opening
    private var deviceObserver: NSObjectProtocol?
    private var pending: [Data] = []            // audio captured before the socket opened
    private var open = false
    private var closing = false
    private var finals: [String] = []
    private var interim = ""
    private var generation = 0                  // callbacks from an earlier recording are ignored

    deinit { teardown() }

    var text: String { (finals + (interim.isEmpty ? [] : [interim])).joined(separator: " ") }

    func toggle() { state == .idle ? start() : stop() }

    func start() {
        guard state == .idle else { return }
        if let other = Self.active, other !== self { other.stop() }
        Self.active = self
        generation += 1
        finals = []; interim = ""; pending = []; open = false; closing = false; lastError = nil
        startedAt = Date(); timeline = []
        state = .connecting
        let gen = generation
        fileAudio = debugAudio
        debugAudio = nil
        if fileAudio != nil { playDebugAudio(gen); connect(gen); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginMic(gen)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    ok ? self.beginMic(gen) : self.fail("Microphone access was denied — allow Multee in System Settings ▸ Privacy & Security ▸ Microphone.")
                }
            }
        default:
            fail("Microphone access is off — allow Multee in System Settings ▸ Privacy & Security ▸ Microphone.")
        }
    }

    /// Stop listening; the last words still arrive (the server answers `CloseStream` with a final transcript),
    /// then the socket closes. Like the CLI: give up waiting after 1.5 s of silence after `CloseStream`, or 5 s in
    /// all. Stopped while the socket is still opening, what was said so far (buffered) is sent once it opens.
    func stop() {
        guard state == .connecting || state == .recording else { return }
        stopMic()
        let gen = generation
        let safety = DispatchWorkItem { [weak self] in if self?.generation == gen { self?.finish() } }
        safetyTimer = safety
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: safety)
        state = .finishing
        if open { closeStream(gen) }
        else if pending.isEmpty { finish() }                // nothing was said yet
        else { closeWhenOpen = true }
    }

    private func closeStream(_ gen: Int) {
        closing = true
        socket?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        let w = DispatchWorkItem { [weak self] in if self?.generation == gen { self?.finish() } }
        noDataTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// The input device changed (headphones plugged in, AirPods connected): AVAudioEngine stops on its own, so the
    /// mic would go quiet while still showing "listening". End the dictation instead, keeping what was heard.
    private func deviceChanged() {
        guard state == .connecting || state == .recording else { return }
        mark("deviceChanged")
        stop()
    }

    func debugDeviceChanged() { deviceChanged() }

    // MARK: - Audio

    private func beginMic(_ gen: Int) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            fail("No microphone found."); return
        }
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            let frames = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
            let data = Data(bytes: p, count: Int(out.frameLength) * 2)
            DispatchQueue.main.async { self?.audio(data, gen) }
        }
        mark("mic")
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone: \(error.localizedDescription)"); return
        }
        self.engine = engine
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in self?.deviceChanged() }
        connect(gen)
    }

    private func stopMic() {
        if let o = deviceObserver { NotificationCenter.default.removeObserver(o); deviceObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func audio(_ data: Data, _ gen: Int) {
        guard gen == generation, !closing else { return }
        if open { socket?.send(.data(data)) { _ in } } else { pending.append(data) }
    }

    /// The harness's stand-in for the mic: the file's samples in 100 ms frames, at speaking pace from the moment it
    /// starts (buffered until the socket opens, as the mic's are), then stop.
    private func playDebugAudio(_ gen: Int) {
        guard let pcm = fileAudio else { return }
        var offset = 0
        func next() {
            guard gen == generation, state == .connecting || state == .recording else { return }
            guard offset < pcm.count else { stop(); return }
            audio(pcm.subdata(in: offset..<min(offset + 3200, pcm.count)), gen)
            offset += 3200
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: next)
        }
        next()
    }

    // MARK: - Socket

    private func connect(_ gen: Int) {
        mark("connect")
        Self.token { [weak self] token in
            guard let self, gen == self.generation else { return }
            self.mark("token")
            self.connect(gen, token)
        }
    }

    private func connect(_ gen: Int, _ token: (access: String, expires: Date?)?) {
        guard let token else {
            fail("Voice needs a claude.ai login — run /login in a Claude tab."); return
        }
        if let expires = token.expires, expires < Date() {
            fail("Claude's login has expired — use any Claude tab once (it refreshes the login), then try again."); return
        }
        var c = URLComponents(string: "wss://api.anthropic.com/api/ws/speech_to_text/voice_stream")!
        c.queryItems = [("encoding", "linear16"), ("sample_rate", "16000"), ("channels", "1"), ("endpointing_ms", "300"),
                        ("utterance_end_ms", "1000"), ("language", "en"), ("use_conversation_engine", "true")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        req.setValue("claude-cli/\(Self.cliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.setValue("claude_code_cli", forHTTPHeaderField: "anthropic-client-platform")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: req)
        self.session = session
        self.socket = socket
        socket.resume()
        receive(socket, gen)
        // URLSessionWebSocketTask queues sends until the handshake is done, and the first send's completion
        // is our "open": it fails if the upgrade is refused.
        socket.send(.string(#"{"type":"KeepAlive"}"#)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let error { self.fail(self.describe(error)); return }
                self.opened(gen)
            }
        }
    }

    private func opened(_ gen: Int) {
        guard state == .connecting || state == .recording || closeWhenOpen else { return }
        open = true
        mark("open")
        for d in pending { socket?.send(.data(d)) { _ in } }
        pending = []
        keepAlive = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.socket?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
        }
        if closeWhenOpen { closeWhenOpen = false; closeStream(gen) }
        else if state == .connecting { state = .recording }
    }

    private func receive(_ socket: URLSessionWebSocketTask, _ gen: Int) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(.string(let s)): self.message(s); self.receive(socket, gen)
                case .success: self.receive(socket, gen)
                case .failure(let error):
                    if self.closing { self.finish() } else { self.fail(self.describe(error)) }
                }
            }
        }
    }

    private func message(_ s: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "TranscriptText", "TranscriptInterim":
            guard let t = (obj["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            if interim.isEmpty, finals.isEmpty { mark("firstText") }
            interim = t
            onText?(text)
            // Words after CloseStream: the final one is coming, stop the "nothing more" timer.
            if closing { noDataTimer?.cancel(); noDataTimer = nil }
        case "TranscriptEndpoint":
            if !interim.isEmpty { finals.append(interim); interim = "" }
            onText?(text)
            if closing { finish() }
        case "TranscriptError", "error":
            let why = (obj["description"] ?? obj["message"] ?? obj["error_code"]) as? String ?? "transcription failed"
            fail(why)
        default: break
        }
    }

    private func describe(_ error: Error) -> String {
        if let r = socket?.response as? HTTPURLResponse, r.statusCode >= 400 {
            if r.statusCode == 401 || r.statusCode == 403 { Self.forgetToken() }
            return r.statusCode == 401 || r.statusCode == 403
                ? "Voice was refused (HTTP \(r.statusCode)) — the claude.ai login may need a refresh: use any Claude tab, then retry."
                : "Voice service answered HTTP \(r.statusCode)."
        }
        return "Voice connection failed: \(error.localizedDescription)"
    }

    private func fail(_ message: String) {
        lastError = message
        teardown()
        onError?(message)
        state = .idle
    }

    private func finish() {
        guard state != .idle else { return }
        if !interim.isEmpty { finals.append(interim); interim = ""; onText?(text) }
        teardown()
        state = .idle
    }

    private func teardown() {
        generation += 1
        stopMic()
        keepAlive?.invalidate(); keepAlive = nil
        noDataTimer?.cancel(); noDataTimer = nil
        safetyTimer?.cancel(); safetyTimer = nil
        closeWhenOpen = false
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        open = false; closing = false; pending = []
        if Self.active === self { Self.active = nil }
    }

    // MARK: - Login + version

    private static var cachedToken: (access: String, expires: Date?)?

    /// Claude Code's claude.ai login, from its Keychain item — through `/usr/bin/security`, as Claude reads it
    /// itself: the item already trusts that tool, where our own `SecItemCopyMatching` took ~3.7 s (the Keychain
    /// checking Multee's signature) on every call. Kept until a minute before it expires. Read-only — Claude
    /// refreshes it itself, and writing a refreshed token here would race its own copy.
    private static func token(_ done: @escaping ((access: String, expires: Date?)?) -> Void) {
        if let t = cachedToken, (t.expires ?? .distantFuture) > Date().addingTimeInterval(60) { done(t); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            var token: (access: String, expires: Date?)?
            if let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let o = j["claudeAiOauth"] as? [String: Any],
               let access = o["accessToken"] as? String, !access.isEmpty {
                token = (access, (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
            }
            DispatchQueue.main.async {
                if let token, (token.expires ?? .distantFuture) > Date() { cachedToken = token }
                done(token)
            }
        }
    }

    /// A refused connection may mean the login moved on (Claude refreshed it): read it afresh next time.
    private static func forgetToken() { cachedToken = nil }

    /// The installed CLI's version for the User-Agent (read once, off-main, at launch of the first chat).
    private(set) static var cliVersion = "2.1.280"
    static func loadCLIVersion() {
        DispatchQueue.global(qos: .utility).async {
            let out = Shell.run(Env.resolve("claude"), ["--version"])
            guard let v = out.split(separator: " ").first, v.first?.isNumber == true else { return }
            DispatchQueue.main.async { cliVersion = String(v) }
        }
    }

    /// 16 kHz mono Int16 samples from an audio file (any format AVFoundation reads) — the harness's voice.
    static func pcm16k(from path: String) -> Data? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil,
              let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 64)
        else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        guard let p = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: p, count: Int(out.frameLength) * 2)
    }
}
