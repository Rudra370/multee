import AppKit

/// Fonts and colors for a chat transcript at one base size. Immutable, so a history render can use it off
/// the main thread (fonts are derived via descriptors, not `NSFontManager`, which is main-thread only).
final class ChatStyle {
    let size: CGFloat
    let body: NSFont, bold: NSFont, italic: NSFont, mono: NSFont, monoSmall: NSFont, small: NSFont
    let h1: NSFont, h2: NSFont, h3: NSFont

    static let text = NSColor(white: 0.87, alpha: 1)
    static let heading = NSColor(white: 0.97, alpha: 1)
    static let dim = NSColor(white: 0.56, alpha: 1)
    static let faint = NSColor(white: 0.42, alpha: 1)
    static let link = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.96, alpha: 1)
    static let inlineCode = NSColor(srgbRed: 0.92, green: 0.70, blue: 0.52, alpha: 1)
    static let inlineCodeBg = NSColor(white: 0.20, alpha: 1)
    static let codeBg = NSColor(white: 0.135, alpha: 1)
    static let codeText = NSColor(white: 0.82, alpha: 1)
    static let border = NSColor(white: 0.30, alpha: 1)
    static let tableHeaderBg = NSColor(white: 0.17, alpha: 1)
    static let green = NSColor(srgbRed: 0.36, green: 0.78, blue: 0.47, alpha: 1)
    static let red = NSColor(srgbRed: 0.94, green: 0.42, blue: 0.40, alpha: 1)
    static let amber = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.32, alpha: 1)
    static let shell = NSColor(srgbRed: 0.99, green: 0.45, blue: 0.72, alpha: 1)   // `!` shell mode (the terminal UI's pink)
    static let addBg = NSColor(srgbRed: 0.16, green: 0.30, blue: 0.19, alpha: 1)
    static let delBg = NSColor(srgbRed: 0.34, green: 0.16, blue: 0.16, alpha: 1)

    init(size: CGFloat) {
        self.size = size
        body = .systemFont(ofSize: size)
        bold = .systemFont(ofSize: size, weight: .semibold)
        italic = Self.trait(.systemFont(ofSize: size), .italic)
        mono = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        small = .systemFont(ofSize: size - 1)
        h1 = .systemFont(ofSize: size + 5, weight: .bold)
        h2 = .systemFont(ofSize: size + 3, weight: .bold)
        h3 = .systemFont(ofSize: size + 1, weight: .semibold)
    }

    static func trait(_ f: NSFont, _ t: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(t)), size: f.pointSize) ?? f
    }
}

/// Markdown → attributed string for assistant replies. Block structure (fences, headings, lists, quotes,
/// tables, rules) is parsed line-by-line; inline formatting uses Foundation's Markdown parser. Chat-sized
/// (smaller headings than the file preview) and thread-safe. Partial input — a reply still streaming with
/// an unclosed fence — renders sensibly: the open fence is code until it closes.
extension NSAttributedString.Key {
    /// On a rendered code block: its source text — the row puts a Copy button on each such block.
    static let chatCode = NSAttributedString.Key("multee.chatCode")
}

extension String {
    /// A native UTF-8 copy. Text decoded by `JSONSerialization` is a bridged `NSString`, on which every
    /// Swift `count`/character walk goes through Objective-C per character — ~100× slower. Render native.
    var native: String { var s = self; s.makeContiguousUTF8(); return s }
    /// Lines of a native copy (unlike `components(separatedBy:)`, which hands back bridged strings).
    var nativeLines: [String] { native.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
}

enum ChatMarkdown {
    static func render(_ source: String, style: ChatStyle) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.nativeLines
        var i = 0
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        while i < lines.count {
            let line = lines[i]
            let t = trimmed(line)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !trimmed(lines[i]).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                out.append(codeBlock(code.joined(separator: "\n"), language: lang.isEmpty ? nil : lang, style: style))
                continue
            }
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [String] = []
                while i < lines.count, lines[i].contains("|"), !trimmed(lines[i]).isEmpty { rows.append(lines[i]); i += 1 }
                out.append(table(rows, style: style))
                continue
            }
            if let (level, text) = heading(t) {
                let font = level == 1 ? style.h1 : level == 2 ? style.h2 : level == 3 ? style.h3 : style.bold
                let p = para(before: level <= 2 ? 8 : 5, after: 3)
                out.append(inline(text, [.font: font, .foregroundColor: ChatStyle.heading, .paragraphStyle: p], style))
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: p]))
                i += 1; continue
            }
            if let f = t.first, f == "-" || f == "*" || f == "_", t.utf8.count >= 3, t.allSatisfy({ $0 == f || $0 == " " }) {
                out.append(rule(style)); i += 1; continue
            }
            if t.hasPrefix(">") {
                var q: [String] = []
                while i < lines.count, trimmed(lines[i]).hasPrefix(">") {
                    q.append(trimmed(String(trimmed(lines[i]).dropFirst()))); i += 1
                }
                out.append(quote(q.joined(separator: "\n"), style: style))
                continue
            }
            if let item = listItem(line) {
                var items = [item]
                i += 1
                while i < lines.count {
                    if let next = listItem(lines[i]) { items.append(next); i += 1; continue }
                    // continuation line of the previous item (indented, non-blank, not a new block)
                    let l = lines[i]
                    if !trimmed(l).isEmpty, l.hasPrefix("  "), !isBlockStart(trimmed(l)) {
                        items[items.count - 1].text += " " + trimmed(l); i += 1; continue
                    }
                    break
                }
                out.append(list(items, style: style))
                continue
            }
            if t.isEmpty { i += 1; continue }
            // A paragraph always takes its first line — even one that merely *looks* like a block start
            // (`#tag`, `| x` without a table separator), else this loop would never advance.
            var paraLines = [t]
            i += 1
            while i < lines.count {
                let l = trimmed(lines[i])
                if l.isEmpty || isBlockStart(l) || listItem(lines[i]) != nil { break }
                paraLines.append(l); i += 1
            }
            let p = para(before: 0, after: 7)
            // Single newlines inside a paragraph are line breaks (as Claude's terminal UI shows them), not new
            // paragraphs — U+2028 keeps them in one paragraph so they don't pick up paragraph spacing.
            out.append(inline(paraLines.joined(separator: "\u{2028}"), [.font: style.body, .foregroundColor: ChatStyle.text, .paragraphStyle: p], style))
            out.append(NSAttributedString(string: "\n", attributes: [.font: style.body, .paragraphStyle: p]))
        }
        trimTrailingNewlines(out)
        return out
    }

    static func trimTrailingNewlines(_ s: NSMutableAttributedString) {
        while s.length > 0, (s.string as NSString).character(at: s.length - 1) == 10 {
            s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1))
        }
    }

    private static func isBlockStart(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func heading(_ t: String) -> (Int, String)? {
        guard t.hasPrefix("#") else { return nil }
        let level = t.prefix(while: { $0 == "#" }).count
        guard level <= 6, t.dropFirst(level).first == " " else { return nil }
        return (level, String(t.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces))
    }

    struct ListItem { var depth: Int; var marker: String; var text: String }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        let depth = min(indent / 2, 6)
        for b in ["- [ ] ", "- [x] ", "- [X] "] where rest.hasPrefix(b) {
            return ListItem(depth: depth, marker: b.contains(" ] ") ? "☐" : "☑", text: String(rest.dropFirst(b.count)))
        }
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            return ListItem(depth: depth, marker: depth % 2 == 0 ? "•" : "◦", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if (after.first == "." || after.first == ")"), after.dropFirst().first == " " {
                return ListItem(depth: depth, marker: "\(digits).", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func list(_ items: [ListItem], style: ChatStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, item) in items.enumerated() {
            let p = NSMutableParagraphStyle()
            let base = CGFloat(item.depth) * 18
            let markerW: CGFloat = item.marker.hasSuffix(".") ? 22 : 14
            p.firstLineHeadIndent = base + 4
            p.headIndent = base + 4 + markerW
            p.tabStops = [NSTextTab(textAlignment: .left, location: base + 4 + markerW)]
            p.paragraphSpacing = n == items.count - 1 ? 7 : 3
            p.lineSpacing = 1.5
            let attrs: [NSAttributedString.Key: Any] = [.font: style.body, .foregroundColor: ChatStyle.text, .paragraphStyle: p]
            var markerAttrs = attrs
            markerAttrs[.foregroundColor] = ChatStyle.dim
            out.append(NSAttributedString(string: item.marker + "\t", attributes: markerAttrs))
            out.append(inline(item.text, attrs, style))
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    private static func para(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = 1.5
        return p
    }

    static func codeBlock(_ code: String, language: String?, style: ChatStyle) -> NSAttributedString {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)      // fill the width (else it collapses)
        block.setWidth(9, type: .absoluteValueType, for: .padding)
        block.backgroundColor = ChatStyle.codeBg
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]; p.paragraphSpacingBefore = 3; p.lineSpacing = 1.5
        let body = code.isEmpty ? " " : code
        // U+2028 keeps the whole block one paragraph → one continuous background.
        let s = NSMutableAttributedString(string: body.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                          attributes: [.font: style.mono, .foregroundColor: ChatStyle.codeText, .paragraphStyle: p])
        if let language, body.utf16.count < 60_000, let hl = TextMateHighlighter.forLanguage(language) {
            for (range, color) in hl.spans(for: body) where NSMaxRange(range) <= s.length {
                s.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        s.append(NSAttributedString(string: "\n", attributes: [.font: style.mono, .paragraphStyle: p]))
        s.addAttribute(.chatCode, value: code as NSString, range: NSRange(location: 0, length: s.length))
        // A plain spacer line after the block. TextKit merges adjacent paragraphs whose text blocks are equal,
        // so two code blocks in a row would otherwise paint as one slab (and paragraph spacing is painted
        // inside a block's background, so it can't separate them).
        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = 8; gap.maximumLineHeight = 8
        s.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: gap]))
        return s
    }

    private static func quote(_ text: String, style: ChatStyle) -> NSAttributedString {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(ChatStyle.border, for: .minX)
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]; p.paragraphSpacing = 7
        let attrs: [NSAttributedString.Key: Any] = [.font: style.italic, .foregroundColor: ChatStyle.dim, .paragraphStyle: p]
        let s = NSMutableAttributedString(attributedString: inline(text.replacingOccurrences(of: "\n", with: "\u{2028}"), attrs, style))
        s.append(NSAttributedString(string: "\n", attributes: attrs))
        return s
    }

    private static func rule(_ style: ChatStyle) -> NSAttributedString {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(ChatStyle.border, for: .minY)
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]; p.paragraphSpacingBefore = 4; p.paragraphSpacing = 10
        return NSAttributedString(string: "\u{00A0}\n", attributes: [.paragraphStyle: p, .font: NSFont.systemFont(ofSize: 2)])
    }

    private static func table(_ raw: [String], style: ChatStyle) -> NSAttributedString {
        let rows: [[String]] = raw.enumerated().compactMap { idx, line in
            if idx == 1 { return nil }
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            return cells
        }
        guard let columns = rows.map(\.count).max(), columns > 0 else { return NSAttributedString() }
        let tbl = NSTextTable()
        tbl.numberOfColumns = columns
        tbl.collapsesBorders = true
        tbl.setContentWidth(100, type: .percentageValueType)
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: tbl, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setBorderColor(ChatStyle.border)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                if r == 0 { cell.backgroundColor = ChatStyle.tableHeaderBg }
                let p = NSMutableParagraphStyle()
                p.textBlocks = [cell]
                let attrs: [NSAttributedString.Key: Any] = [.font: r == 0 ? style.bold : style.body,
                                                            .foregroundColor: ChatStyle.text, .paragraphStyle: p]
                out.append(inline(c < row.count ? row[c] : "", attrs, style))
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        let gap = NSMutableParagraphStyle(); gap.paragraphSpacing = 4
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: gap]))
        return out
    }

    /// Inline Markdown (bold, italic, `code`, links, strikethrough) over `base` attributes.
    static func inline(_ text: String, _ base: [NSAttributedString.Key: Any], _ style: ChatStyle) -> NSAttributedString {
        guard text.contains(where: { "*_`[~<".contains($0) }) else { return NSAttributedString(string: text, attributes: base) }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let baseFont = base[.font] as? NSFont ?? style.body
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = base
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { font = ChatStyle.trait(font, .bold) }
                if intent.contains(.emphasized) { font = ChatStyle.trait(font, .italic) }
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                    attrs[.foregroundColor] = ChatStyle.inlineCode
                    attrs[.backgroundColor] = ChatStyle.inlineCodeBg
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attrs[.font] = font
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = ChatStyle.link
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}

/// Item → attributed string. One string per row, so a row is a single selectable text view. Tool rows
/// mimic Claude's terminal UI: `Tool(summary)` then a `⎿` result preview; long output collapses behind a
/// "show more" link (a `multee-chat://toggle/<id>` URL the row intercepts).
enum ChatRender {
    static let previewLines = 4
    static let expandedLineCap = 600

    static func render(_ item: ChatItem, style: ChatStyle, cwd: String) -> NSAttributedString {
        switch item.kind {
        case .user:
            return user(item, style: style)
        case .assistant:
            let s = ChatMarkdown.render(capped(item.text), style: style)
            if s.length == 0 { return NSAttributedString(string: "…", attributes: [.font: style.body, .foregroundColor: ChatStyle.dim]) }
            return s
        case .thinking:
            let s = NSMutableAttributedString(string: "Thinking", attributes: [.font: ChatStyle.trait(style.small, .italic), .foregroundColor: ChatStyle.dim])
            if item.expanded {
                s.append(NSAttributedString(string: "\n" + item.text, attributes: [.font: ChatStyle.trait(style.small, .italic), .foregroundColor: ChatStyle.faint, .paragraphStyle: para(1.5)]))
                s.append(toggleLink(item, "  hide", style))
            } else {
                s.append(toggleLink(item, "  show", style))
            }
            return s
        case .notice:
            return linkified(NSMutableAttributedString(string: capped(item.text), attributes: [.font: style.small, .foregroundColor: ChatStyle.dim, .paragraphStyle: para(1.5)]))
        case .error:
            return NSAttributedString(string: item.text, attributes: [.font: style.small, .foregroundColor: ChatStyle.red, .paragraphStyle: para(1.5)])
        case .tool:
            return tool(item, style: style, cwd: cwd)
        }
    }

    /// Your message: the pictures it carried, then the text with their `[Image #n]` markers taken out —
    /// the marker is only how the box tracks an image, and the picture itself says it better. The images are
    /// text attachments, so the same TextKit pass that measures the row measures them.
    private static func user(_ item: ChatItem, style: ChatStyle) -> NSAttributedString {
        let text = item.images.isEmpty ? item.text
                                       : ChatAttachment.stripMarkers(item.text, keeping: []).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = NSMutableAttributedString()
        if !item.images.isEmpty {
            let line = NSMutableParagraphStyle()
            line.lineSpacing = 4
            for image in item.images {
                let a = NSTextAttachment()
                a.image = image
                a.bounds = CGRect(origin: .zero, size: image.size)
                out.append(NSAttributedString(attachment: a))
                out.append(NSAttributedString(string: " "))
            }
            out.addAttribute(.paragraphStyle, value: line, range: NSRange(location: 0, length: out.length))
            if !text.isEmpty { out.append(NSAttributedString(string: "\n")) }
        }
        let body = NSAttributedString(string: capped(text),
                                      attributes: [.font: style.body, .foregroundColor: ChatStyle.text, .paragraphStyle: para(1.5)])
        out.append(body)
        return out
    }

    /// Web links in plain text (a notice carrying the Remote Control session link) become clickable.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static func linkified(_ s: NSMutableAttributedString) -> NSAttributedString {
        guard s.string.contains("://"), let d = linkDetector else { return s }
        for m in d.matches(in: s.string, range: NSRange(location: 0, length: s.length)) {
            guard let url = m.url, url.scheme?.hasPrefix("http") == true else { continue }
            s.addAttributes([.link: url, .foregroundColor: ChatStyle.link], range: m.range)
        }
        return s
    }

    /// Very long messages (a pasted log) render their first 60k characters; "Copy Message" copies all.
    static let textCap = 60_000
    static func capped(_ s: String) -> String {
        let n = s.native
        guard n.utf8.count > textCap else { return n }
        let head = String(n.prefix(textCap))
        return head + "\n\n… \((n.utf8.count - head.utf8.count) / 1024) KB more — use Copy Message for the full text"
    }

    private static func para(_ spacing: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle(); p.lineSpacing = spacing; return p
    }

    private static func toggleLink(_ item: ChatItem, _ label: String, _ style: ChatStyle) -> NSAttributedString {
        NSAttributedString(string: label, attributes: [.font: style.small, .foregroundColor: ChatStyle.link,
                                                       .link: URL(string: "multee-chat://toggle/\(item.id)")!])
    }

    // MARK: Tool rows

    /// Display name: the terminal UI's names, and `mcp__server__tool` as "server · tool".
    static func toolTitle(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : name
        }
        switch name {
        case "Task", "Agent": return "Agent"
        case "AskUserQuestion": return "Question"
        case "ExitPlanMode": return "Plan"
        case "Edit", "MultiEdit": return "Update"
        default: return name
        }
    }

    /// A path as the chat shows it: relative inside the repo; outside it, home as ~ and very long paths
    /// trimmed to their last components.
    static func displayPath(_ p: String, cwd: String) -> String {
        guard !cwd.isEmpty else { return p }
        // The session path is standardized (`/tmp/x`); Claude reports the resolved one (`/private/tmp/x`).
        let path = p.hasPrefix("/private/") && !cwd.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        let home = NSHomeDirectory()
        let short = path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
        let parts = short.split(separator: "/")
        return short.count > 70 && parts.count > 3 ? "…/" + parts.suffix(3).joined(separator: "/") : short
    }

    /// The one-line argument summary shown in `Tool(summary)`.
    static func toolSummary(_ name: String, _ input: [String: Any], cwd: String = "") -> String {
        func str(_ k: String) -> String? { (input[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func rel(_ p: String) -> String { displayPath(p, cwd: cwd) }
        let s: String
        switch name {
        case "Bash": s = str("command") ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": s = rel(str("file_path") ?? str("notebook_path") ?? "")
        case "Grep":
            let pattern = str("pattern") ?? ""
            s = "\"\(pattern)\"" + (str("path").map { " in \(rel($0))" } ?? "") + (str("glob").map { " (\($0))" } ?? "")
        case "Glob": s = str("pattern") ?? ""
        case "WebFetch": s = str("url") ?? ""
        case "WebSearch": s = str("query") ?? ""
        case "Task", "Agent": s = str("description") ?? ""
        case "Skill": s = str("skill") ?? str("command") ?? ""
        case "TodoWrite", "ExitPlanMode", "AskUserQuestion": s = ""
        default:
            s = input.keys.sorted().lazy.compactMap { (input[$0] as? String) }.first ?? ""
        }
        let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    private static func tool(_ item: ChatItem, style: ChatStyle, cwd: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let name = item.toolName
        let summary = toolSummary(name, item.toolInput, cwd: cwd)
        let headerPara = para(1.5)
        if item.isShell {       // a command you ran: `! git status`, as typed
            out.append(NSAttributedString(string: "! ", attributes: [.font: style.bold, .foregroundColor: ChatStyle.shell, .paragraphStyle: headerPara]))
            out.append(NSAttributedString(string: item.toolInput["command"] as? String ?? "", attributes: [.font: style.mono, .foregroundColor: ChatStyle.heading, .paragraphStyle: headerPara]))
        } else {
            out.append(NSAttributedString(string: toolTitle(name), attributes: [.font: style.bold, .foregroundColor: ChatStyle.heading, .paragraphStyle: headerPara]))
            if !summary.isEmpty {
                out.append(NSAttributedString(string: "(\(summary))", attributes: [.font: style.body, .foregroundColor: ChatStyle.dim, .paragraphStyle: headerPara]))
            }
        }

        var body = NSMutableAttributedString()
        switch name {
        case "Edit", "MultiEdit":
            body = diffBody(item, style: style)
        case "Write":
            let content = item.toolInput["content"] as? String ?? ""
            let n = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
            if item.toolStatus == .done {
                let link = content.isEmpty || item.expanded ? nil : toggleLink(item, "  show", style)
                body.append(resultLines(["Wrote \(n) line\(n == 1 ? "" : "s")"], style: style, color: ChatStyle.dim, link: link))
                if item.expanded, !content.isEmpty { body.append(codePreview(content, item: item, style: style, cap: expandedLineCap)) }
            } else if item.toolStatus == .failed, let r = item.toolResult {
                body.append(resultLines([r.components(separatedBy: "\n").first ?? r], style: style, color: ChatStyle.red))
            }
        case "TodoWrite":
            body = todoBody(item, style: style)
        case "ExitPlanMode":
            // While waiting, the approval card shows the plan — don't print it twice.
            if item.toolStatus != .waiting, let plan = item.toolInput["plan"] as? String, !plan.isEmpty {
                body.append(NSAttributedString(string: "\n"))
                body.append(ChatMarkdown.render(plan, style: style))
            }
        case "AskUserQuestion":
            let qs = (item.toolInput["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            var lines = qs.map { "? " + $0 }
            if let r = item.toolResult, item.toolStatus == .done,
               let answers = ChatHistory.between(r, "answered: ", ". You can") { lines.append("→ " + answers) }
            body.append(resultLines(lines, style: style, color: ChatStyle.dim))
        case "Task", "Agent":
            if item.toolStatus == .running || item.toolStatus == .waiting {
                var line = item.subagentSteps > 0 ? "\(item.subagentSteps) tool use\(item.subagentSteps == 1 ? "" : "s")" : "Starting…"
                if let last = item.subagentLast { line += " · \(last)" }
                body.append(resultLines([line], style: style, color: ChatStyle.dim))
            } else if let r = item.toolResult {
                body.append(collapsible(cleanAgentResult(r), item: item, style: style, mono: false))
            }
        case "Read":
            if let r = item.toolResult, item.toolStatus == .done {
                let n = r.isEmpty ? 0 : r.components(separatedBy: "\n").count
                let link = n == 0 || item.expanded ? nil : toggleLink(item, "  show", style)
                body.append(resultLines(["Read \(n) line\(n == 1 ? "" : "s")"], style: style, color: ChatStyle.dim, link: link))
                if item.expanded { body.append(codePreview(r, item: item, style: style, cap: expandedLineCap)) }
            }
        case "Bash" where (item.toolResult ?? "").hasPrefix("Command running in background"):
            body.append(resultLines(["Running in the background — see Background tasks"], style: style, color: ChatStyle.dim))
        default:
            if let r = item.toolResult, item.toolStatus != .denied { body.append(collapsible(r, item: item, style: style, mono: true)) }
        }
        // Status lines the result doesn't cover (each starts on its own line).
        func newline() { if body.length > 0, !body.string.hasSuffix("\n") { body.append(NSAttributedString(string: "\n", attributes: [.font: style.small])) } }
        switch item.toolStatus {
        case .running where item.isShell:
            body.append(resultLines(["Running… (esc stops it)"], style: style, color: ChatStyle.faint))
        case .waiting:
            newline()
            let what = name == "AskUserQuestion" ? "Waiting for your answer…" : name == "ExitPlanMode" ? "Waiting for you to review the plan…" : "Waiting for your approval…"
            body.append(resultLines([what], style: style, color: ChatStyle.amber))
        case .denied:
            let why = (item.toolResult ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let generic = why.isEmpty || why.hasPrefix("The user denied") || why == "User denied"
            if item.toolName != "Edit", item.toolName != "MultiEdit" {   // the diff body already shows the refusal
                body = NSMutableAttributedString(attributedString: resultLines([generic ? "Denied" : "Denied — “\(why)”"], style: style, color: ChatStyle.red))
            }
        case .interrupted:
            if item.toolResult == nil || body.length == 0 || item.toolName == "Write" {
                newline(); body.append(resultLines(["Interrupted"], style: style, color: ChatStyle.faint))
            }
        default: break
        }
        if body.length > 0 {
            out.append(NSAttributedString(string: "\n", attributes: [.font: style.small]))
            out.append(body)
        }
        ChatMarkdown.trimTrailingNewlines(out)
        return out
    }

    /// A subagent's report, minus the harness framing meant for Claude: the "[Subagent hand-back] …
    /// The report follows:" preamble, the report's two-space indent, and the trailing agentId / <usage> lines.
    /// Async launch receipts (internal ids + instructions) become a one-liner.
    static func cleanAgentResult(_ r: String) -> String {
        if r.hasPrefix("Async agent launched") { return "Running in the background" }
        var body = r
        if body.hasPrefix("[Subagent hand-back]"), let m = body.range(of: "The report follows:") {
            body = String(body[m.upperBound...])
        }
        if let u = body.range(of: "\n<usage>") { body = String(body[..<u.lowerBound]) }
        let lines = body.nativeLines.filter { !$0.hasPrefix("agentId: ") }
        return lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `⎿`-prefixed dim lines (the terminal UI's result gutter). The gutter glyph is set in the system font
    /// (monospaced fonts lack it, and a wider fallback glyph would push the tab past its stop and wrap).
    static let resultIndent: CGFloat = 26

    private static func resultLines(_ lines: [String], style: ChatStyle, color: NSColor, mono: Bool = false,
                                    link: NSAttributedString? = nil) -> NSAttributedString {
        let first = NSMutableParagraphStyle()
        first.firstLineHeadIndent = 6; first.headIndent = resultIndent; first.lineSpacing = 1
        first.tabStops = [NSTextTab(textAlignment: .left, location: resultIndent)]
        let rest = NSMutableParagraphStyle()
        rest.firstLineHeadIndent = resultIndent; rest.headIndent = resultIndent; rest.lineSpacing = 1
        let font = mono ? style.monoSmall : style.small
        let out = NSMutableAttributedString()
        for (n, l) in lines.enumerated() {
            let p = n == 0 ? first : rest
            if n == 0 {
                out.append(NSAttributedString(string: "⎿\t", attributes: [.font: style.small, .foregroundColor: ChatStyle.faint, .paragraphStyle: p]))
            }
            out.append(NSAttributedString(string: l, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
            if n == lines.count - 1, let link { out.append(link) }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: p]))
        }
        return out
    }

    /// A dim trailer line under a result ("… +12 lines show more"), aligned with the result text.
    private static func trailer(_ text: String, _ style: ChatStyle) -> NSMutableAttributedString {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = resultIndent; p.headIndent = resultIndent
        return NSMutableAttributedString(string: "\n" + text, attributes: [.font: style.small, .foregroundColor: ChatStyle.faint, .paragraphStyle: p])
    }

    /// A result shown as its first few lines, expandable to (a capped) everything.
    private static func collapsible(_ raw: String, item: ChatItem, style: ChatStyle, mono: Bool) -> NSAttributedString {
        let text = ChatHistory.stripANSI(raw).trimmingCharacters(in: .newlines).native
        guard !text.isEmpty else {
            return resultLines([item.toolStatus == .failed ? "Failed" : "(no output)"], style: style, color: ChatStyle.faint)
        }
        let all = text.nativeLines
        let limit = item.expanded ? expandedLineCap : previewLines
        let shown = all.prefix(limit).map { $0.count > 400 ? String($0.prefix(399)) + "…" : $0 }
        let color = item.toolStatus == .failed ? ChatStyle.red : ChatStyle.dim
        let out = NSMutableAttributedString(attributedString: resultLines(shown, style: style, color: color, mono: mono))
        if all.count > limit {
            ChatMarkdown.trimTrailingNewlines(out)
            let more = trailer(item.expanded ? "… \(all.count - limit) more lines not shown  " : "… +\(all.count - limit) lines  ", style)
            more.append(toggleLink(item, item.expanded ? "show less" : "show more", style))
            out.append(more)
        } else if item.expanded, all.count > previewLines {
            ChatMarkdown.trimTrailingNewlines(out)
            let less = trailer("", style)
            less.append(toggleLink(item, "show less", style))
            out.append(less)
        }
        return out
    }

    private static func codePreview(_ text: String, item: ChatItem, style: ChatStyle, cap: Int) -> NSAttributedString {
        let lines = text.nativeLines
        let shown = lines.prefix(cap).joined(separator: "\n")
        let out = NSMutableAttributedString(attributedString: ChatMarkdown.codeBlock(shown, language: nil, style: style))
        if lines.count > cap {
            out.append(NSAttributedString(string: "… \(lines.count - cap) more lines not shown\n", attributes: [.font: style.small, .foregroundColor: ChatStyle.faint]))
        }
        out.append(toggleLink(item, "hide", style))
        return out
    }

    /// Edit/MultiEdit as a red/green line diff of old_string → new_string.
    private static func diffBody(_ item: ChatItem, style: ChatStyle) -> NSMutableAttributedString {
        var edits: [(String, String)] = []
        if let list = item.toolInput["edits"] as? [[String: Any]] {
            edits = list.map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
        } else if item.toolInput["old_string"] != nil || item.toolInput["new_string"] != nil {
            edits = [(item.toolInput["old_string"] as? String ?? "", item.toolInput["new_string"] as? String ?? "")]
        }
        let out = NSMutableAttributedString()
        if item.toolStatus == .failed || item.toolStatus == .denied, let r = item.toolResult {
            let first = r.components(separatedBy: "\n").first ?? r
            out.append(resultLines([item.toolStatus == .denied ? "Denied — “\(first)”" : first], style: style, color: ChatStyle.red))
            return out
        }
        var lines: [(String, Bool)] = []   // (text, isAdd)
        for (old, new) in edits {
            let o = old.isEmpty ? [] : old.nativeLines
            let n = new.isEmpty ? [] : new.nativeLines
            // Trim the shared prefix/suffix so a one-line change inside a big context shows as one line.
            var start = 0
            while start < o.count, start < n.count, o[start] == n[start] { start += 1 }
            var endO = o.count, endN = n.count
            while endO > start, endN > start, o[endO - 1] == n[endN - 1] { endO -= 1; endN -= 1 }
            lines += o[start..<endO].map { ($0, false) } + n[start..<endN].map { ($0, true) }
        }
        let added = lines.filter { $0.1 }.count, removed = lines.count - added
        out.append(resultLines(["\(added) addition\(added == 1 ? "" : "s"), \(removed) removal\(removed == 1 ? "" : "s")"], style: style, color: ChatStyle.dim))
        let cap = item.expanded ? expandedLineCap : 12
        // Consecutive +/− lines render as one text block each (a clean colored band; per-line background
        // attributes bleed into the indent on wrapped lines). U+2028 keeps a run in one paragraph.
        var shown = Array(lines.prefix(cap))
        while !shown.isEmpty {
            let add = shown[0].1
            let run = shown.prefix { $0.1 == add }
            shown.removeFirst(run.count)
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(resultIndent, type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .padding)
            block.backgroundColor = add ? ChatStyle.addBg : ChatStyle.delBg
            let p = NSMutableParagraphStyle()
            p.textBlocks = [block]
            let text = run.map { (add ? "+ " : "- ") + ($0.0.count > 300 ? String($0.0.prefix(299)) + "…" : $0.0) }
                .joined(separator: "\u{2028}")
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: style.monoSmall, .foregroundColor: add ? ChatStyle.green : ChatStyle.red, .paragraphStyle: p]))
        }
        if lines.count > cap || (item.expanded && lines.count > 12) {
            ChatMarkdown.trimTrailingNewlines(out)
            let more = trailer(lines.count > cap ? "… +\(lines.count - cap) lines  " : "", style)
            more.append(toggleLink(item, lines.count > cap ? "show all" : "show less", style))
            out.append(more)
        }
        return out
    }

    private static func todoBody(_ item: ChatItem, style: ChatStyle) -> NSMutableAttributedString {
        let todos = item.toolInput["todos"] as? [[String: Any]] ?? []
        let out = NSMutableAttributedString()
        let p = NSMutableParagraphStyle(); p.firstLineHeadIndent = resultIndent; p.headIndent = resultIndent + 18; p.lineSpacing = 1
        for t in todos {
            let content = t["content"] as? String ?? ""
            let status = t["status"] as? String ?? "pending"
            let (mark, color, strike): (String, NSColor, Bool) = status == "completed" ? ("☑", ChatStyle.faint, true)
                : status == "in_progress" ? ("◐", ChatStyle.amber, false) : ("☐", ChatStyle.text, false)
            var attrs: [NSAttributedString.Key: Any] = [.font: style.small, .foregroundColor: color, .paragraphStyle: p]
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: "\(mark)  \(content)\n", attributes: attrs))
        }
        return out
    }
}

/// Measures attributed strings with the same TextKit 1 stack the row's text view uses, so a precomputed
/// height is exactly the rendered height (no estimate to correct while scrolling — the scroll-jump cause).
/// One instance per thread.
final class ChatMeasurer {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layout.backgroundLayoutEnabled = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        container.size = NSSize(width: max(20, width), height: .greatestFiniteMagnitude)
        storage.setAttributedString(s)
        layout.ensureLayout(for: container)
        let h = layout.usedRect(for: container).height
        storage.setAttributedString(NSAttributedString())
        return ceil(max(h, 1))
    }
}
