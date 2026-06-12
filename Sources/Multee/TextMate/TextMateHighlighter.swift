import AppKit

// A compact TextMate-grammar syntax highlighter driven by NSRegularExpression — the regex engine
// built into macOS, so there's no bundled engine to ship and no JavaScript VM at runtime (this
// replaced Highlightr, which spun up JavaScriptCore at ~150 MB per process). Grammars are small
// .tmLanguage.json data files (the same ones VS Code/Sublime use), loaded lazily per language.
//
// Supports match rules, begin/end rules (with captures + nested patterns) and #repository / $self
// includes — the common case. External-grammar includes (e.g. HTML embedding CSS) and Oniguruma-only
// regex features that ICU rejects are skipped: that region just stays base-colored. The result is
// "good", not "tree-sitter-perfect" — the right trade for a file viewer in a terminal-centric app.

// MARK: - Resource bundle

/// Resolves the SwiftPM resource bundle (`Multee_Multee.bundle`) holding the grammar JSON.
///
/// `Bundle.module`'s generated accessor only checks the `.app` *root* and the build-machine path, so
/// a distributed `.app` (which must keep resources in `Contents/Resources/`) would `fatalError`. We
/// check `Bundle.main.resourceURL` first — the same fix the vendored Highlightr used — and only fall
/// back to `Bundle.module` when running outside a packaged `.app` (e.g. `swift run`), where it
/// resolves via the baked build path.
private enum GrammarBundle {
    static let bundle: Bundle? = {
        if let res = Bundle.main.resourceURL {
            let url = res.appendingPathComponent("Multee_Multee.bundle")
            if let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }()
}

// MARK: - Grammar model (Codable over the .tmLanguage.json shape)

final class TMRule: Decodable {
    let name: String?
    let contentName: String?
    let match: String?
    let begin: String?
    let end: String?
    let include: String?
    let captures: [String: TMCapture]?
    let beginCaptures: [String: TMCapture]?
    let endCaptures: [String: TMCapture]?
    let patterns: [TMRule]?

    private enum CodingKeys: String, CodingKey {
        case name, contentName, match, begin, end, include, captures, beginCaptures, endCaptures, patterns
    }

    // Compiled regexes, built once on first use and cached for the grammar's lifetime.
    lazy var matchRe = TMRule.compile(match)
    lazy var beginRe = TMRule.compile(begin)
    lazy var endRe = TMRule.compile(end)

    static func compile(_ pattern: String?) -> NSRegularExpression? {
        guard let pattern else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

struct TMCapture: Decodable { let name: String? }

final class TMGrammar: Decodable {
    let scopeName: String
    let patterns: [TMRule]
    let repository: [String: TMRule]?
}

// MARK: - Theme (atom-one-dark palette; longest-scope-prefix wins)

enum TMTheme {
    static let background = NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1) // #282C34
    static let base       = NSColor(srgbRed: 0.671, green: 0.698, blue: 0.749, alpha: 1) // #ABB2BF

    private static func c(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let gray   = c(0x5C6370), green  = c(0x98C379), orange = c(0xD19A66)
    private static let purple = c(0xC678DD), blue   = c(0x61AFEF), teal   = c(0x56B6C2)
    private static let yellow = c(0xE5C07B), red    = c(0xE06C75)

    // Scope → color. Longest matching prefix wins, so specific scopes override general ones.
    private static let map: [(String, NSColor)] = [
        ("comment", gray),
        ("punctuation.definition.comment", gray),
        ("string", green),
        ("punctuation.definition.string", green),
        ("constant.numeric", orange),
        ("constant.character", orange),
        ("constant.language", orange),
        ("constant.other", orange),
        ("constant", orange),
        ("keyword.operator", teal),
        ("keyword", purple),
        ("storage.type", purple),
        ("storage.modifier", purple),
        ("storage", purple),
        ("entity.name.function", blue),
        ("entity.name.type", yellow),
        ("entity.name.class", yellow),
        ("entity.name.tag", red),
        ("entity.name.section", red),
        ("entity.other.attribute-name", yellow),
        ("entity.other.inherited-class", yellow),
        ("entity.name", yellow),
        ("support.function", blue),
        ("support.type", teal),
        ("support.class", yellow),
        ("support.constant", orange),
        ("support", teal),
        ("variable.language", red),
        ("variable.parameter", base),
        ("variable", red),
        ("markup.heading", red),
        ("markup.bold", orange),
        ("markup.italic", orange),
        ("markup.inline.raw", green),
        ("markup.underline.link", blue),
    ]

    static func color(for scope: String) -> NSColor? {
        var best: NSColor?; var bestLen = -1
        for (prefix, color) in map where prefix.count > bestLen {
            if scope == prefix || scope.hasPrefix(prefix + ".") { best = color; bestLen = prefix.count }
        }
        return best
    }
}

// MARK: - Highlighter

final class TextMateHighlighter {
    private let grammar: TMGrammar

    // Anchors/lookaround see the full string and ^/$ never falsely fire at a sub-range's edge — so
    // tokenizing the *content* of a begin/end region (a mid-line sub-range) stays correct.
    private static let matchOptions: NSRegularExpression.MatchingOptions =
        [.withTransparentBounds, .withoutAnchoringBounds]

    private init(grammar: TMGrammar) {
        self.grammar = grammar
        // Force every rule's lazy regex to compile now, on the construction thread. After this the
        // grammar is immutable, so `spans(for:)` is a pure read and is safe to run on any thread
        // (the editor tokenizes small files on main and large files on a background queue).
        precompile(grammar.patterns)
        if let repository = grammar.repository { precompile(Array(repository.values)) }
    }

    private func precompile(_ rules: [TMRule]) {
        for rule in rules {
            _ = rule.matchRe; _ = rule.beginRe; _ = rule.endRe
            if let nested = rule.patterns { precompile(nested) }
        }
    }

    // MARK: Loading & caching

    /// Compiled highlighter per grammar, reused across every editor (regexes compiled once → low RAM/CPU).
    private static var cache: [String: TextMateHighlighter] = [:]

    /// Highlighter for a file, by extension / well-known filename. `nil` → no grammar (plain text).
    static func forPath(_ path: String) -> TextMateHighlighter? {
        guard let language = language(forPath: path) else { return nil }
        if let hit = cache[language] { return hit }
        guard let url = GrammarBundle.bundle?.url(forResource: language, withExtension: "json", subdirectory: "Grammars"),
              let data = try? Data(contentsOf: url),
              let grammar = try? JSONDecoder().decode(TMGrammar.self, from: data) else { return nil }
        let hl = TextMateHighlighter(grammar: grammar)
        cache[language] = hl
        return hl
    }

    /// Map a file path to a bundled grammar key. Filename is checked first (Dockerfile, Makefile),
    /// then the extension.
    static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile":           return "dockerfile"
        case "makefile", "gnumakefile":                return "makefile"
        case ".gitignore", ".gitattributes", ".gitconfig": return "ini"
        default: break
        }
        return extToLanguage[(path as NSString).pathExtension.lowercased()]
    }

    private static let extToLanguage: [String: String] = [
        "swift": "swift",
        "py": "python", "pyw": "python", "pyi": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "json": "json", "jsonc": "json",
        "go": "go",
        "rs": "rust",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "c++": "cpp",
        "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "m": "objc", "mm": "objc",
        "java": "java",
        "rb": "ruby", "rake": "ruby", "gemspec": "ruby",
        "php": "php",
        "html": "html", "htm": "html", "xhtml": "html",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "sh": "shell", "bash": "shell", "zsh": "shell", "ksh": "shell",
        "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "markdown": "markdown",
        "sql": "sql",
        "xml": "xml", "svg": "xml", "plist": "xml", "xsd": "xml",
        "ini": "ini", "cfg": "ini", "conf": "ini", "toml": "ini",
        "bat": "bat", "cmd": "bat",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "mk": "makefile",
        "pl": "perl", "pm": "perl",
        "lua": "lua",
    ]

    // MARK: Tokenizing

    /// One open begin/end region on the tokenizer stack: its `end` regex, the child patterns that can
    /// match inside it, and the colour applied to its bare content (contentName ?? name ?? parent's).
    private struct Frame {
        let rule: TMRule?                       // nil for the root frame
        let endRegex: NSRegularExpression?      // nil for the root frame
        let patterns: [TMRule]                  // expanded child rules active inside this region
        let contentColor: NSColor?              // colour for text not claimed by a child token
    }

    /// Colour spans for `text`, produced **line by line** so each regex only scans within the current
    /// line (≈80 chars) rather than the whole document — linear in file size. begin/end state carries
    /// across lines on a stack, so multi-line strings/comments stay correct. Spans are emitted in
    /// application order (outer scopes first, inner override).
    func spans(for text: String) -> [(NSRange, NSColor)] {
        let ns = text as NSString
        var out: [(NSRange, NSColor)] = []
        var stack = [Frame(rule: nil, endRegex: nil,
                           patterns: expand(grammar.patterns, visited: []), contentColor: nil)]
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            self.tokenizeLine(lineRange, text: text, stack: &stack, out: &out)
        }
        return out
    }

    /// Flatten includes ($self / #repository / grouping rules) into concrete match|begin rules.
    private func expand(_ rules: [TMRule], visited: Set<String>) -> [TMRule] {
        var result: [TMRule] = []
        for rule in rules {
            if let include = rule.include {
                if visited.contains(include) { continue }
                var next = visited; next.insert(include)
                if include == "$self" || include == "$base" {
                    result += expand(grammar.patterns, visited: next)
                } else if include.hasPrefix("#"), let target = grammar.repository?[String(include.dropFirst())] {
                    if target.match != nil || target.begin != nil { result.append(target) }
                    else if let nested = target.patterns { result += expand(nested, visited: next) }
                }
                // External-grammar includes (e.g. "source.css") are skipped.
            } else if rule.match != nil || rule.begin != nil {
                result.append(rule)
            } else if let nested = rule.patterns {
                result += expand(nested, visited: visited)
            }
        }
        return result
    }

    /// Tokenize one line, mutating the carried `stack` and appending colour spans. All regex searches
    /// are confined to `[pos, lineEnd)`; per-rule next-matches are cached for the duration of the line.
    private func tokenizeLine(_ lineRange: NSRange, text: String,
                              stack: inout [Frame], out: inout [(NSRange, NSColor)]) {
        let lineEnd = lineRange.location + lineRange.length
        var pos = lineRange.location
        var nextMatch = [ObjectIdentifier: NSTextCheckingResult?]()   // per-rule cache, this line only
        var iterations = 0

        while pos <= lineEnd {
            iterations += 1; if iterations > 100_000 { break }   // guard against zero-width-match cycles
            let top = stack[stack.count - 1]

            // Earliest child match (a new token or nested region) in the rest of the line.
            var bestRule: TMRule?; var best: NSTextCheckingResult?; var bestStart = lineEnd + 1
            for rule in top.patterns {
                guard let regex = rule.match != nil ? rule.matchRe : rule.beginRe else { continue }
                let id = ObjectIdentifier(rule)
                let match: NSTextCheckingResult?
                if let cached = nextMatch[id] { match = cached }
                else {
                    match = regex.firstMatch(in: text, options: Self.matchOptions,
                                             range: NSRange(location: pos, length: lineEnd - pos))
                    nextMatch[id] = match
                }
                if let match, match.range.location < bestStart { bestStart = match.range.location; best = match; bestRule = rule }
            }

            // The current region's end, if any, in the rest of the line.
            let endMatch = top.endRegex?.firstMatch(in: text, options: Self.matchOptions,
                                                    range: NSRange(location: pos, length: lineEnd - pos))

            if let end = endMatch, best == nil || end.range.location <= bestStart {
                // End wins (starts no later than the best child) → close the region.
                paint(pos, end.range.location, top.contentColor, &out)
                if let rule = top.rule {
                    if let name = rule.name, let color = TMTheme.color(for: name) { out.append((end.range, color)) }
                    applyCaptures(rule.endCaptures ?? rule.captures, match: end, out: &out)
                }
                stack.removeLast()
                pos = end.range.location + end.range.length     // zero-width (lookahead) end: parent resumes here
            } else if let rule = bestRule, let match = best {
                paint(pos, match.range.location, top.contentColor, &out)
                if let name = rule.name, let color = TMTheme.color(for: name) { out.append((match.range, color)) }
                if rule.begin != nil, let endRegex = rule.endRe {
                    // Open a nested region; its content inherits contentName ?? name ?? parent colour.
                    applyCaptures(rule.beginCaptures ?? rule.captures, match: match, out: &out)
                    let contentColor = rule.contentName.flatMap { TMTheme.color(for: $0) }
                        ?? rule.name.flatMap { TMTheme.color(for: $0) } ?? top.contentColor
                    stack.append(Frame(rule: rule, endRegex: endRegex,
                                       patterns: expand(rule.patterns ?? [], visited: []), contentColor: contentColor))
                } else {
                    applyCaptures(rule.captures, match: match, out: &out)   // plain match rule (begin w/o end → match)
                }
                pos = match.range.location + max(match.range.length, 1)
            } else {
                paint(pos, lineEnd, top.contentColor, &out)   // nothing more matches on this line
                break
            }

            if pos >= lineEnd { break }
            for (id, cached) in nextMatch where (cached?.range.location ?? Int.max) < pos { nextMatch.removeValue(forKey: id) }
        }
    }

    /// Append a colour span for `[from, to)` if non-empty and the scope maps to a colour.
    private func paint(_ from: Int, _ to: Int, _ color: NSColor?, _ out: inout [(NSRange, NSColor)]) {
        guard let color, to > from else { return }
        out.append((NSRange(location: from, length: to - from), color))
    }

    private func applyCaptures(_ captures: [String: TMCapture]?, match: NSTextCheckingResult,
                               out: inout [(NSRange, NSColor)]) {
        guard let captures else { return }
        for (key, capture) in captures {
            guard let index = Int(key), let name = capture.name, let color = TMTheme.color(for: name),
                  index < match.numberOfRanges else { continue }
            let range = match.range(at: index)
            if range.location != NSNotFound && range.length > 0 { out.append((range, color)) }
        }
    }
}
