import Foundation

/// Project-wide text search scoped to one repo. Shells out to `git grep` — every Multee session is a git
/// repo, so there's no extra dependency: it respects `.gitignore`, is fast, and (with `--untracked`)
/// covers tracked *and* new-but-not-ignored files, matching VS Code's default search scope. Cheap to call
/// off-main; the caller debounces and runs it on a background queue.
enum ProjectSearch {
    struct Options: Equatable {
        var matchCase = false
        var wholeWord = false
        var regex = false
    }

    struct Match { let line: Int; let preview: String }
    struct FileHits { let file: String; let matches: [Match] }

    struct Result {
        let files: [FileHits]
        /// `git grep` errored (e.g. an invalid regex) — distinct from simply finding nothing.
        let failed: Bool
        var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
    }

    /// Run a search. Empty query → empty result (no subprocess). Caps total matches so a pathological
    /// query (a single char across a huge tree) stays light.
    static func run(_ query: String, in repo: String, options: Options, maxMatches: Int = 5000) -> Result {
        guard !query.isEmpty else { return Result(files: [], failed: false) }

        var args = ["grep", "--no-color", "-n", "-I", "--untracked", "--full-name"]
        if !options.matchCase { args.append("-i") }
        if options.wholeWord { args.append("-w") }
        args.append(options.regex ? "-E" : "-F")     // extended regex, or fixed-string literal
        args.append(contentsOf: ["-e", query])

        let r = Shell.runFull(Env.resolve("git"), args, cwd: repo)
        // git grep exit codes: 0 = matches found, 1 = none, >1 = error (bad regex, not a repo, …).
        if r.code > 1 { return Result(files: [], failed: true) }

        var files: [FileHits] = []
        var curFile: String?
        var curMatches: [Match] = []
        var total = 0
        func flush() {
            if let f = curFile, !curMatches.isEmpty { files.append(FileHits(file: f, matches: curMatches)) }
            curMatches = []
        }
        for raw in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
            if total >= maxMatches { break }
            guard let parsed = parse(String(raw)) else { continue }
            if parsed.file != curFile { flush(); curFile = parsed.file }       // git groups a file's matches together
            curMatches.append(Match(line: parsed.line, preview: parsed.preview))
            total += 1
        }
        flush()
        return Result(files: files, failed: false)
    }

    /// Parse one `git grep -n` line: `FILE:LINE:TEXT`. Returns nil when the second field isn't numeric —
    /// which also harmlessly drops the rare path-with-a-colon that would mis-split.
    private static func parse(_ s: String) -> (file: String, line: Int, preview: String)? {
        guard let c1 = s.firstIndex(of: ":") else { return nil }
        let file = String(s[..<c1])
        let afterFile = s[s.index(after: c1)...]
        guard let c2 = afterFile.firstIndex(of: ":"), let line = Int(afterFile[..<c2]) else { return nil }
        var text = String(afterFile[afterFile.index(after: c2)...])
        text = String(text.drop(while: { $0 == " " || $0 == "\t" }))      // trim indentation so previews align
        if text.count > 500 { text = String(text.prefix(500)) }           // clip minified/huge lines
        return (file, line, text)
    }
}
