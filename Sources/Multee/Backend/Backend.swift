import Foundation

/// Shell / process helpers.
enum Shell {
    /// Run a command, capture stdout as a string (trimmed). Returns "" on failure.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw bytes of a command's stdout (for NUL-delimited git output).
    static func runData(_ launchPath: String, _ args: [String], cwd: String? = nil) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

enum Env {
    /// The user's login-shell PATH (GUI apps get a minimal PATH that omits ~/.local/bin etc).
    /// Defaults to the trivial env PATH; `bootstrap()` (called once at startup) replaces it with
    /// the full login-shell PATH.
    static var loginPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    /// Compute the login-shell PATH once at app launch. Spawns a subprocess, so it must be called
    /// from startup — never lazily from a deep call path that could re-enter the run loop.
    static func bootstrap() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let out = Shell.run(shell, ["-l", "-i", "-c", "printf '%s' \"$PATH\""])
        if !out.isEmpty { loginPath = out }
    }

    /// Resolve a program name to an absolute path using the login PATH.
    static func resolve(_ program: String) -> String {
        if program.contains("/") { return program }
        for dir in loginPath.split(separator: ":") {
            let cand = "\(dir)/\(program)"
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
        }
        return program
    }

    /// Environment as "KEY=VALUE" strings, with the full login PATH and any extras applied.
    static func array(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        env["TERM"] = "xterm-256color"
        for (k, v) in extra { env[k] = v }
        return env.map { "\($0)=\($1)" }
    }
}
