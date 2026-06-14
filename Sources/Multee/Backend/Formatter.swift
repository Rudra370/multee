import Foundation

/// One formatter: how to detect it, run it (stdin → stdout), and install it.
struct FormatterSpec {
    let id: String
    let name: String                 // "Prettier"
    let exts: [String]               // file extensions it handles (lowercased, no dot)
    let binaries: [String]           // candidate executable names (first found wins)
    let argv: (_ bin: String, _ path: String) -> [String]   // full argv incl. the resolved binary
    let brew: String?                // Homebrew install command, if one exists
    let native: String               // the ecosystem's own install command
    let docs: String?

    /// Preferred install command: Homebrew where available, else the native one.
    var installCommand: String { brew ?? native }
}

/// Format-on-demand via the user's installed CLI formatters (shelled out, never bundled — zero idle
/// cost). Detection prefers a project-local tool (`node_modules/.bin`) over a global one, and the
/// formatter runs with `cwd` = the file's directory so it discovers project config (`.prettierrc`, …).
enum Formatter {
    static let specs: [FormatterSpec] = [
        FormatterSpec(id: "prettier", name: "Prettier",
                      exts: ["js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "jsonc", "css", "scss",
                             "less", "html", "vue", "md", "markdown", "yaml", "yml", "graphql"],
                      binaries: ["prettier"],
                      argv: { bin, path in [bin, "--stdin-filepath", path] },
                      brew: nil, native: "npm install -g prettier", docs: "https://prettier.io"),
        FormatterSpec(id: "gofmt", name: "gofmt", exts: ["go"], binaries: ["gofmt"],
                      argv: { bin, _ in [bin] },
                      brew: "brew install go", native: "Install Go from https://go.dev/dl",
                      docs: "https://pkg.go.dev/cmd/gofmt"),
        FormatterSpec(id: "rustfmt", name: "rustfmt", exts: ["rs"], binaries: ["rustfmt"],
                      argv: { bin, _ in [bin, "--edition", "2021"] },
                      brew: nil, native: "rustup component add rustfmt",
                      docs: "https://github.com/rust-lang/rustfmt"),
        FormatterSpec(id: "ruff", name: "Ruff", exts: ["py", "pyi"], binaries: ["ruff"],
                      argv: { bin, path in [bin, "format", "--stdin-filename", path, "-"] },
                      brew: "brew install ruff", native: "pipx install ruff",
                      docs: "https://docs.astral.sh/ruff/formatter/"),
        FormatterSpec(id: "swift-format", name: "swift-format", exts: ["swift"], binaries: ["swift-format"],
                      argv: { bin, _ in [bin, "format"] },
                      brew: "brew install swift-format", native: "brew install swift-format",
                      docs: "https://github.com/swiftlang/swift-format"),
        FormatterSpec(id: "clang-format", name: "clang-format",
                      exts: ["c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "m", "mm"],
                      binaries: ["clang-format"],
                      argv: { bin, path in [bin, "--assume-filename=\(path)"] },
                      brew: "brew install clang-format", native: "brew install clang-format",
                      docs: "https://clang.llvm.org/docs/ClangFormat.html"),
    ]

    static func spec(forPath path: String) -> FormatterSpec? {
        let ext = (path as NSString).pathExtension.lowercased()
        return specs.first { $0.exts.contains(ext) }
    }

    enum Outcome {
        case formatted(String)        // new text (differs from input)
        case unchanged                // already formatted
        case noFormatter(String)      // no spec for this extension (carries the ext)
        case notInstalled(FormatterSpec)
        case failed(String)           // formatter exited non-zero — carries stderr
    }

    /// Run the matching formatter against `text`. Safe to call off the main thread.
    static func format(text: String, path: String) -> Outcome {
        guard let spec = spec(forPath: path) else {
            return .noFormatter((path as NSString).pathExtension.lowercased())
        }
        let dir = (path as NSString).deletingLastPathComponent
        guard let bin = resolveBinary(spec, near: dir) else { return .notInstalled(spec) }
        let (out, err, code) = runPipe(spec.argv(bin, path), cwd: dir, stdin: text)
        guard code == 0 else {
            return .failed(err.isEmpty ? "\(spec.name) exited with code \(code)." : err)
        }
        // Safety: a formatter should never turn non-empty source into nothing — refuse to wipe the file.
        if out.isEmpty && !text.isEmpty {
            return .failed(err.isEmpty ? "\(spec.name) produced no output." : err)
        }
        return out == text ? .unchanged : .formatted(out)
    }

    /// Absolute path to the formatter binary — project-local (`node_modules/.bin`, walking up from the
    /// file) first, then the login PATH. `nil` if it isn't installed anywhere reachable.
    private static func resolveBinary(_ spec: FormatterSpec, near dir: String) -> String? {
        let fm = FileManager.default
        for bin in spec.binaries {
            var d = dir
            while d.count > 1 {
                let cand = "\(d)/node_modules/.bin/\(bin)"
                if fm.isExecutableFile(atPath: cand) { return cand }
                let parent = (d as NSString).deletingLastPathComponent
                if parent == d { break }
                d = parent
            }
        }
        for bin in spec.binaries {
            for pathDir in Env.loginPath.split(separator: ":") {
                let cand = "\(pathDir)/\(bin)"
                if fm.isExecutableFile(atPath: cand) { return cand }
            }
        }
        return nil
    }

    /// Is this formatter installed (for the management page / detection)? `dir` lets project-local count.
    static func isInstalled(_ spec: FormatterSpec, near dir: String = FileManager.default.currentDirectoryPath) -> Bool {
        resolveBinary(spec, near: dir) != nil
    }

    /// Run a process feeding `stdin`, capturing stdout + stderr + exit code. stdin is written and stderr
    /// read on background threads so a large input/error stream can't deadlock against the stdout read.
    private static func runPipe(_ argv: [String], cwd: String, stdin: String) -> (out: String, err: String, code: Int32) {
        guard let exe = argv.first else { return ("", "no command", 1) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Env.loginPath
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return ("", error.localizedDescription, 1) }

        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
            try? inPipe.fileHandleForWriting.close()
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                p.terminationStatus)
    }
}

/// Bridge for the "Install" button: the editor layer can't reach the session model, so
/// `CenterViewController` registers this to open a Terminal tab running the install command.
enum FormatterInstall {
    static var run: ((_ command: String) -> Void)?
}
