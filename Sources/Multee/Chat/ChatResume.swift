import AppKit

/// Past conversations for a folder — what Claude's `/resume` picker lists (print mode refuses `/resume`, so
/// the chat has its own). Claude keeps them as `~/.claude/projects/<encoded cwd>/<id>.jsonl`, encoding the
/// folder's real path with every non-alphanumeric character as `-`.
enum ChatResume {
    struct Entry { let id: String; let title: String; let modified: Date; let bytes: Int }

    /// Claude's per-project folders for `cwd` (as given and its real path — they differ under /tmp).
    static func projectDirs(cwd: String) -> [String] {
        var paths = [cwd]
        if let r = realpath(cwd, nil) { paths.append(String(cString: r)); free(r) }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var dirs: [String] = []
        for p in paths {
            let enc = String(p.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
            let dir = base.appendingPathComponent(enc).path
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs
    }

    /// Newest first, at most `limit`. Reads a bounded head/tail per file for the title — run off-main.
    static func list(cwd: String, excluding: String?, limit: Int = 100) -> [Entry] {
        var files: [(String, Date, Int)] = []
        for dir in projectDirs(cwd: cwd) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(n)
                guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                files.append((path, a[.modificationDate] as? Date ?? .distantPast, (a[.size] as? NSNumber)?.intValue ?? 0))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [Entry] = []
        for (path, date, size) in files {
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard id != excluding, size > 0 else { continue }
            // A file with no prompt in it (a session that never got a message) isn't worth resuming.
            guard let title = ClaudeTranscript.title(path: path) else { continue }
            out.append(Entry(id: id, title: title.replacingOccurrences(of: "\n", with: " "), modified: date, bytes: size))
            if out.count >= limit { break }
        }
        return out
    }

    static func detail(_ e: Entry) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        let size = ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file)
        return "\(f.localizedString(for: e.modified, relativeTo: Date())) · \(size)"
    }
}

/// A search-and-pick list in the chat's bottom column (like the prompt card) — /resume, /rewind and
/// /memory use it. ↑/↓ move, ⏎ picks, esc closes.
final class ChatPickerPanel: NSView, NSTextFieldDelegate {
    struct Entry { let id: String; let title: String; let detail: String }

    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let list = ChatCompletionView()
    private let status = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!
    private var all: [Entry] = []
    private(set) var shown: [Entry] = []
    private var newestLast = false          // entries run oldest → newest; start on the newest (bottom)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.155, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = ChatStyle.heading
        let close = ClosureButton(symbol: "xmark", pointSize: 10) { [weak self] in self?.onClose?() }
        close.toolTip = "Close (esc)"
        let top = NSStackView(views: [titleLabel, NSView(), close])
        top.orientation = .horizontal
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = ChatStyle.faint
        list.onPick = { [weak self] i in self?.pick(i) }
        let v = NSStackView(views: [top, field, list, status])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        listHeight = list.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -24),
            field.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -24),
            list.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -24),
            listHeight,
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Show empty with a title; entries follow via `setEntries` (possibly after an off-main load).
    func present(title: String, placeholder: String, fontSize: CGFloat) {
        titleLabel.stringValue = title
        field.placeholderString = placeholder
        list.fontSize = fontSize - 1
        field.stringValue = ""
        status.stringValue = "Loading…"
        status.isHidden = false
        all = []
        filter()
    }

    func setEntries(_ entries: [Entry], empty: String, newestLast: Bool = false) {
        all = entries
        self.newestLast = newestLast
        status.stringValue = entries.isEmpty ? empty : ""
        status.isHidden = !entries.isEmpty
        filter()
    }

    func focus() { window?.makeFirstResponder(field) }

    private func filter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.id.hasPrefix(q) }
        list.set(shown.map { ($0.title, $0.detail) }, selectLast: newestLast)
        listHeight.constant = shown.isEmpty ? 0 : list.preferredHeight
        list.isHidden = shown.isEmpty
    }

    private func pick(_ i: Int) {
        guard shown.indices.contains(i) else { return }
        onPick?(shown[i].id)
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): list.move(1); return true
        case #selector(NSResponder.moveUp(_:)): list.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(list.selected); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    // DEV harness
    func debugPick(_ i: Int) { pick(i) }
    var debugSelected: Int { list.selected }
}
