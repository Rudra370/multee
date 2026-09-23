import AppKit

/// `/export`: the conversation as Markdown — your messages, Claude's replies, and a one-line entry per tool
/// call (thinking and tool output are left out, as in the terminal UI's export).
enum ChatExport {
    static func markdown(_ items: [ChatItem], title: String, cwd: String, date: Date = Date()) -> String {
        let stamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        var out = "# \(title)\n\nClaude Code conversation · `\(cwd)` · exported \(stamp)\n"
        var speaker: ChatItem.Kind?          // who the current section belongs to (.user / .assistant)
        func section(_ who: ChatItem.Kind) {
            guard speaker != who else { return }
            speaker = who
            out += "\n---\n\n### \(who == .user ? "You" : "Claude")\n"
        }
        for item in items {
            switch item.kind {
            case .user:
                section(.user)
                out += "\n" + item.text + "\n"
            case .assistant:
                section(.assistant)
                out += "\n" + item.text + "\n"
            case .tool:
                section(.assistant)
                let summary = ChatRender.toolSummary(item.toolName, item.toolInput, cwd: cwd)
                let status: String
                switch item.toolStatus {
                case .failed: status = " — failed"
                case .denied: status = " — denied"
                case .interrupted: status = " — interrupted"
                default: status = ""
                }
                out += "\n- `\(ChatRender.toolTitle(item.toolName))`" + (summary.isEmpty ? "" : " \(summary)") + status + "\n"
            case .notice:
                out += "\n*\(item.text)*\n"
            case .error:
                out += "\n> **Error:** \(item.text.replacingOccurrences(of: "\n", with: "\n> "))\n"
            case .thinking:
                break
            }
        }
        return out
    }

    /// `2026-09-21-143005-fix-the-login-bug.md` — the terminal UI's export name, as Markdown.
    static func defaultName(title: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return f.string(from: date) + (slug.isEmpty ? "" : "-" + String(slug.prefix(40))) + ".md"
    }

    /// `/export <file>`: `~` expanded, relative to the chat's folder, `.md` added when there's no extension.
    static func resolve(_ arg: String, cwd: String) -> String {
        var p = (arg as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
        if (p as NSString).pathExtension.isEmpty { p += ".md" }
        return p
    }
}

/// `/memory`: the CLAUDE.md files Claude loads for this folder, opened in Multee's editor.
enum ChatMemory {
    struct File { let title: String; let path: String; let note: String }

    /// Project and user memory always (created on open, like the terminal UI); the others when they exist.
    static func files(cwd: String) -> [File] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var out = [File(title: "Project memory", path: (cwd as NSString).appendingPathComponent("CLAUDE.md"),
                        note: "checked in — shared with your team")]
        for (rel, title, note) in [(".claude/CLAUDE.md", "Project memory (.claude)", "checked in — shared with your team"),
                                   ("CLAUDE.local.md", "Project memory (local)", "just you, this project")] {
            let p = (cwd as NSString).appendingPathComponent(rel)
            if fm.fileExists(atPath: p) { out.append(File(title: title, path: p, note: note)) }
        }
        out.append(File(title: "User memory", path: home + "/.claude/CLAUDE.md", note: "just you, every project"))
        for dir in ChatResume.projectDirs(cwd: cwd) {
            let p = dir + "/memory/MEMORY.md"
            if fm.fileExists(atPath: p) { out.append(File(title: "Auto memory", path: p, note: "Claude’s own notes for this project")); break }
        }
        return out
    }

    /// Create the file (and its folder) if it's new, so the editor opens something saveable.
    static func ensure(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        do {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            return fm.createFile(atPath: path, contents: Data())
        } catch { return false }
    }
}

/// `!` shell mode: one command in your shell, in the chat's folder — output shown in the chat and handed
/// to Claude (see `ChatSession.runShell`). Commands that keep running (a dev server) are stopped after
/// `timeout`; those belong in a terminal tab or a background task.
enum ChatShell {
    struct Result {
        var stdout: String, stderr: String
        var status: Int32
        var stopNote: String?               // "[stopped]" — esc or the timeout ended it
        /// The line that says it didn't succeed — "[stopped]" or "[exit code 1]" — shown with the output and
        /// sent to Claude with it (the transcript keeps no exit status, so history reads it back from here).
        var failureNote: String? { stopNote ?? (status != 0 ? "[exit code \(status)]" : nil) }
    }

    static let timeout: TimeInterval = 120
    static let contextCap = 30_000          // characters of output Claude gets (the Bash tool's own limit)
    private static let keepBytes = 2 * 1024 * 1024

    /// Output collected off-main; capped so a runaway command can't fill memory.
    private final class Sink {
        private let lock = NSLock()
        private var data = Data()
        private(set) var eof = false
        func add(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            if d.isEmpty { eof = true } else if data.count < keepBytes { data.append(d.prefix(keepBytes - data.count)) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return ChatHistory.stripANSI(String(decoding: data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Start `command` (`$SHELL -c`); `done` runs on main once it exits. Nil if the shell couldn't start.
    static func run(_ command: String, cwd: String, done: @escaping (Result) -> Void) -> Process? {
        let p = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Env.loginPath
        for k in ChatSession.parentSessionEnv { env[k] = nil }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe(), out = Sink(), err = Sink()
        p.standardOutput = outPipe
        p.standardError = errPipe
        for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                sink.add(d)
                if d.isEmpty { h.readabilityHandler = nil }
            }
        }
        let timedOut = Flag()
        p.terminationHandler = { proc in
            DispatchQueue.global(qos: .userInitiated).async {
                // Let the pipes drain; a child left running in the background may hold them open — don't wait on it.
                for _ in 0..<10 where !(out.eof && err.eof) { usleep(50_000) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let signaled = proc.terminationReason == .uncaughtSignal
                let note = timedOut.value ? "[stopped after \(Int(timeout)) s — run long-lived commands in a terminal tab]"
                    : signaled ? "[stopped]" : nil
                let r = Result(stdout: out.text, stderr: err.text, status: proc.terminationStatus, stopNote: note)
                DispatchQueue.main.async { done(r) }
            }
        }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard p.isRunning else { return }
            timedOut.value = true
            p.terminate()
        }
        return p
    }

    /// Output as Claude gets it: at most `contextCap` characters.
    static func capped(_ s: String) -> String {
        guard s.count > contextCap else { return s }
        return String(s.prefix(contextCap)) + "\n… [\(s.count - contextCap) more characters truncated]"
    }

    private final class Flag { var value = false }
}

/// A pasted image, encoded for Claude: at most `maxEdge` on the long side (Anthropic's recommended size —
/// bigger costs tokens without helping), PNG, or JPEG when the PNG would be heavy (a photo or a screenshot).
enum ChatImage {
    static let maxEdge: CGFloat = 1568
    static let pngLimit = 1_500_000
    static let byteLimit = 4_500_000          // the API's per-image ceiling is 5 MB

    static func encoded(_ image: NSImage) -> (data: Data, mediaType: String)? {
        guard let cg = fit(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= pngLimit {
            return (png, "image/png")
        }
        for quality in [0.8, 0.6, 0.4] {
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { break }
            if jpeg.count <= byteLimit { return (jpeg, "image/jpeg") }
        }
        return rep.representation(using: .png, properties: [:]).map { ($0, "image/png") }
    }

    /// The image as a bitmap, scaled down so neither side is over `maxEdge`.
    private static func fit(_ image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        guard scale < 1 else { return cg }
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return cg }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? cg
    }
}
