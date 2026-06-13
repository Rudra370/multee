import AppKit

/// Renders Markdown to an `NSAttributedString` for the preview. Block structure (headings, lists,
/// blockquotes, fenced code, tables, rules, images) is parsed here line-by-line; inline formatting
/// (**bold**, *italic*, `code`, links, images) is parsed by Foundation's Markdown engine and its
/// intents mapped to fonts. Fenced code blocks are syntax-highlighted with the TextMate engine, tables
/// use `NSTextTable`, and local images render inline as attachments. Native — no WebKit, no deps.
enum MarkdownRenderer {

    // MARK: Theme

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 26, weight: .bold)
        case 2: return .systemFont(ofSize: 21, weight: .bold)
        case 3: return .systemFont(ofSize: 17, weight: .semibold)
        case 4: return .systemFont(ofSize: 15, weight: .semibold)
        default: return .systemFont(ofSize: 13, weight: .semibold)
        }
    }
    private static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    private static func bold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
    private static func italic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

    private static let textColor = NSColor(white: 0.85, alpha: 1)
    private static let headingColor = NSColor(white: 0.97, alpha: 1)
    private static let linkColor = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.96, alpha: 1)
    private static let inlineCodeColor = NSColor(srgbRed: 0.92, green: 0.70, blue: 0.52, alpha: 1)
    private static let inlineCodeBg = NSColor(white: 0.20, alpha: 1)
    private static let codeBlockBg = NSColor(white: 0.145, alpha: 1)
    private static let codeBlockText = NSColor(white: 0.82, alpha: 1)
    private static let quoteColor = NSColor(white: 0.62, alpha: 1)
    private static let quoteBar = NSColor(white: 0.40, alpha: 1)
    private static let ruleColor = NSColor(white: 0.32, alpha: 1)
    private static let tableBorder = NSColor(white: 0.32, alpha: 1)
    private static let tableHeaderBg = NSColor(white: 0.17, alpha: 1)

    // MARK: Entry point

    static func render(_ source: String, baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: collect lines until the closing ``` / ~~~ fence.
            if let lang = fenceLanguage(trimmed) {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("```") || t.hasPrefix("~~~") { i += 1; break }
                    code.append(lines[i]); i += 1
                }
                out.append(codeBlock(code.joined(separator: "\n"), language: lang.isEmpty ? nil : lang))
                continue
            }

            // Table (header row followed by a |---|---| separator)
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [String] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(lines[i]); i += 1
                }
                out.append(table(rows, baseURL: baseURL))
                continue
            }

            // Heading
            if let (level, text) = heading(trimmed) { out.append(headingBlock(text, level: level, baseURL: baseURL)); i += 1; continue }

            // Horizontal rule
            if isRule(trimmed) { out.append(ruleBlock()); i += 1; continue }

            // Blockquote (consecutive `>` lines)
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(quoteBlock(quote.joined(separator: " "), baseURL: baseURL))
                continue
            }

            // Lists (consecutive bullet / numbered items)
            if listMarker(line) != nil {
                var items: [(marker: String, text: String)] = []
                while i < lines.count, let m = listMarker(lines[i]) {
                    items.append(m); i += 1
                }
                out.append(listBlock(items, baseURL: baseURL))
                continue
            }

            // Blank line
            if trimmed.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])); i += 1; continue }

            // Paragraph (consecutive plain lines)
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isBlockStart(lines[i]) { break }
                para.append(t); i += 1
            }
            out.append(paragraphBlock(para.joined(separator: " "), baseURL: baseURL))
        }
        return out
    }

    // MARK: Block detection

    private static func isBlockStart(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return heading(t) != nil || isRule(t) || t.hasPrefix(">") || listMarker(line) != nil
            || fenceLanguage(t) != nil || (t.hasPrefix("|") )
    }

    private static func fenceLanguage(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 { level += 1; idx = trimmed.index(after: idx) }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        return (level, String(trimmed[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let chars = Set(trimmed.replacingOccurrences(of: " ", with: ""))
        return trimmed.count >= 3 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    private static func listMarker(_ line: String) -> (marker: String, text: String)? {
        let t = line.drop(while: { $0 == " " })
        if let first = t.first, "-*+".contains(first), t.dropFirst().first == " " {
            return ("•", String(t.dropFirst(2)))
        }
        // numbered: digits then "."
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = t.dropFirst(digits.count)
            if rest.first == ".", rest.dropFirst().first == " " {
                return ("\(digits).", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        let cells = t.split(separator: "|", omittingEmptySubsequences: true)
        return !cells.isEmpty && cells.allSatisfy { Set($0.trimmingCharacters(in: .whitespaces)).isSubset(of: [":", "-"]) }
    }

    // MARK: Block builders

    private static func headingBlock(_ text: String, level: Int, baseURL: URL?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = level <= 2 ? 14 : 10
        para.paragraphSpacing = 5
        let base: [NSAttributedString.Key: Any] = [.font: headingFont(level), .foregroundColor: headingColor, .paragraphStyle: para]
        let r = NSMutableAttributedString(attributedString: inline(text, base: base, baseURL: baseURL))
        r.append(NSAttributedString(string: "\n", attributes: base))
        return r
    }

    private static func paragraphBlock(_ text: String, baseURL: URL?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 8; para.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: para]
        let r = NSMutableAttributedString(attributedString: inline(text, base: base, baseURL: baseURL))
        r.append(NSAttributedString(string: "\n", attributes: base))
        return r
    }

    private static func listBlock(_ items: [(marker: String, text: String)], baseURL: URL?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.headIndent = 22; para.firstLineHeadIndent = 8; para.paragraphSpacing = 3; para.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: para]
        for item in items {
            result.append(NSAttributedString(string: "\(item.marker)  ", attributes: base))
            result.append(inline(item.text, base: base, baseURL: baseURL))
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
        return result
    }

    private static func quoteBlock(_ text: String, baseURL: URL?) -> NSAttributedString {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)   // fill width (else it collapses to ~0)
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(quoteBar, for: .minX)
        let para = NSMutableParagraphStyle()
        para.textBlocks = [block]; para.paragraphSpacingBefore = 6; para.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: italic(bodyFont), .foregroundColor: quoteColor, .paragraphStyle: para]
        let r = NSMutableAttributedString(attributedString: inline(text, base: base, baseURL: baseURL))
        r.append(NSAttributedString(string: "\n", attributes: base))
        return r
    }

    private static func codeBlock(_ code: String, language: String?) -> NSAttributedString {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)   // fill width (else it collapses to ~0)
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.backgroundColor = codeBlockBg
        let para = NSMutableParagraphStyle()
        para.textBlocks = [block]; para.paragraphSpacingBefore = 6; para.paragraphSpacing = 6; para.lineSpacing = 2
        // Soft line breaks (U+2028) keep multi-line code as ONE paragraph → one continuous background.
        let oneParagraph = code.replacingOccurrences(of: "\n", with: "\u{2028}")
        let attr = NSMutableAttributedString(string: oneParagraph,
            attributes: [.font: mono(12.5), .foregroundColor: codeBlockText, .paragraphStyle: para])
        if let language, let hl = TextMateHighlighter.forLanguage(language) {
            for (range, color) in hl.spans(for: code) where NSMaxRange(range) <= attr.length {
                attr.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        attr.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para, .font: mono(12.5)]))
        return attr
    }

    private static func ruleBlock() -> NSAttributedString {
        let block = NSTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(ruleColor, for: .minY)
        let para = NSMutableParagraphStyle()
        para.textBlocks = [block]; para.paragraphSpacingBefore = 10; para.paragraphSpacing = 10
        return NSAttributedString(string: "\u{00A0}\n", attributes: [.paragraphStyle: para, .font: NSFont.systemFont(ofSize: 1)])
    }

    private static func table(_ rawRows: [String], baseURL: URL?) -> NSAttributedString {
        // Split into cells; drop the separator row.
        let rows: [[String]] = rawRows.enumerated().compactMap { (idx, line) in
            if idx == 1 { return nil }   // |---|---| separator
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            return cells
        }
        guard let columns = rows.map(\.count).max(), columns > 0 else { return NSAttributedString() }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        let result = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            let isHeader = (r == 0)
            for c in 0..<columns {
                let cellBlock = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cellBlock.setBorderColor(tableBorder)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                if isHeader { cellBlock.backgroundColor = tableHeaderBg }
                let para = NSMutableParagraphStyle()
                para.textBlocks = [cellBlock]
                let base: [NSAttributedString.Key: Any] = [
                    .font: isHeader ? bold(bodyFont) : bodyFont, .foregroundColor: textColor, .paragraphStyle: para,
                ]
                let cellText = c < row.count ? row[c] : ""
                result.append(inline(cellText, base: base, baseURL: baseURL))
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        return result
    }

    // MARK: Inline (Foundation parse → fonts/attachments)

    private static func inline(_ text: String, base: [NSAttributedString.Key: Any], baseURL: URL?) -> NSAttributedString {
        let baseFont = (base[.font] as? NSFont) ?? bodyFont
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            // Inline image → attachment (local files only; remote falls back to alt text).
            if let imageURL = run.imageURL, let attachment = imageAttachment(imageURL, baseURL: baseURL) {
                result.append(NSAttributedString(attachment: attachment))
                continue
            }
            let chunk = String(parsed[run.range].characters)
            var attrs = base
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { font = bold(font) }
                if intent.contains(.emphasized) { font = italic(font) }
                if intent.contains(.code) {
                    font = mono(baseFont.pointSize)
                    attrs[.foregroundColor] = inlineCodeColor
                    attrs[.backgroundColor] = inlineCodeBg
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attrs[.font] = font
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: chunk, attributes: attrs))
        }
        return result
    }

    private static func imageAttachment(_ url: URL, baseURL: URL?) -> NSTextAttachment? {
        let resolved: URL
        if url.scheme == nil {
            resolved = baseURL?.appendingPathComponent(url.relativePath) ?? url   // relative path
        } else if url.isFileURL {
            resolved = url
        } else {
            return nil   // remote (http) images — don't fetch over the network in a viewer; show alt text
        }
        guard let image = NSImage(contentsOf: resolved) else { return nil }
        let maxWidth: CGFloat = 520
        if image.size.width > maxWidth {
            image.size = NSSize(width: maxWidth, height: image.size.height * (maxWidth / image.size.width))
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        return attachment
    }
}
