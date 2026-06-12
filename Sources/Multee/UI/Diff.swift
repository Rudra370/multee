import AppKit

// MARK: - Line diff (pure; drives both unified and split views)

enum DiffRow {
    case equal(old: Int, new: Int, text: String)
    case del(old: Int, text: String)
    case ins(new: Int, text: String)
    case change(old: Int, new: Int, oldText: String, newText: String)
}

/// Line-level diff using the standard library's Myers diff.
func computeDiff(old: String, new: String) -> [DiffRow] {
    let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
    let diff = newLines.difference(from: oldLines)
    var removed = Set<Int>(), inserted = Set<Int>()
    for ch in diff {
        switch ch {
        case .remove(let o, _, _): removed.insert(o)
        case .insert(let o, _, _): inserted.insert(o)
        }
    }
    var rows: [DiffRow] = []
    var i = 0, j = 0
    while i < oldLines.count || j < newLines.count {
        let oRem = i < oldLines.count && removed.contains(i)
        let nIns = j < newLines.count && inserted.contains(j)
        if oRem && nIns {
            rows.append(.change(old: i + 1, new: j + 1, oldText: oldLines[i], newText: newLines[j])); i += 1; j += 1
        } else if oRem {
            rows.append(.del(old: i + 1, text: oldLines[i])); i += 1
        } else if nIns {
            rows.append(.ins(new: j + 1, text: newLines[j])); j += 1
        } else if i < oldLines.count && j < newLines.count {
            rows.append(.equal(old: i + 1, new: j + 1, text: oldLines[i])); i += 1; j += 1
        } else if i < oldLines.count {
            rows.append(.del(old: i + 1, text: oldLines[i])); i += 1
        } else {
            rows.append(.ins(new: j + 1, text: newLines[j])); j += 1
        }
    }
    return rows
}

// MARK: - Colors

private let addBg = NSColor(red: 0.16, green: 0.30, blue: 0.18, alpha: 1)
private let delBg = NSColor(red: 0.34, green: 0.16, blue: 0.16, alpha: 1)
private let addFg = NSColor(red: 0.60, green: 0.86, blue: 0.62, alpha: 1)
private let delFg = NSColor(red: 0.92, green: 0.62, blue: 0.60, alpha: 1)
private let gutterFg = NSColor(white: 0.40, alpha: 1)
private let diffTextFg = NSColor(white: 0.82, alpha: 1)
private func diffFont() -> NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

private struct UnifiedLine { let oldNo: Int?; let newNo: Int?; let sign: String; let text: String; let bg: NSColor; let fg: NSColor }

// MARK: - Diff view controller (NSTableView)

/// Renders a file's diff vs HEAD, unified or split. Built from `computeDiff` rows. One row per line;
/// full-width row background carries add/del color. Split shows old | new columns.
final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let repo: String   // repo root
    let path: String   // repo-relative path
    private let onOpenFile: () -> Void

    private var rows: [DiffRow] = []
    private var unified: [UnifiedLine] = []
    private var split: Bool
    private var loaded = false

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No changes vs HEAD")
    private let seg: PointerSegmentedControl = {
        let s = PointerSegmentedControl()
        s.segmentCount = 2
        s.setLabel("Unified", forSegment: 0)
        s.setLabel("Split", forSegment: 1)
        s.trackingMode = .selectOne
        return s
    }()

    init(repo: String, path: String, onOpenFile: @escaping () -> Void) {
        self.repo = repo
        self.path = path
        self.onOpenFile = onOpenFile
        self.split = UserDefaults.standard.bool(forKey: "diffSplit")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.118, alpha: 1).cgColor

        // Header: path + Unified/Split + open-to-edit.
        let pathLabel = NSTextField(labelWithString: path)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = NSColor(white: 0.8, alpha: 1)
        pathLabel.lineBreakMode = .byTruncatingMiddle

        seg.selectedSegment = split ? 1 : 0
        seg.target = self
        seg.action = #selector(toggleSplit)
        seg.segmentStyle = .rounded
        seg.controlSize = .small
        seg.toolTip = "Unified / Split view"

        let openBtn = PointerButton()
        openBtn.title = "Edit"
        openBtn.target = self
        openBtn.action = #selector(openTapped)
        openBtn.bezelStyle = .inline
        openBtn.controlSize = .small
        openBtn.toolTip = "Open file to edit"

        let header = NSStackView(views: [pathLabel, NSView(), seg, openBtn])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.backgroundColor = NSColor(white: 0.118, alpha: 1)
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.rowHeight = 17
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openTapped)
        configureColumns()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.118, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor(white: 0.45, alpha: 1)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()
    }

    private func configureColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        if split {
            let old = NSTableColumn(identifier: .init("old")); old.width = 500; old.minWidth = 120
            let new = NSTableColumn(identifier: .init("new")); new.width = 500; new.minWidth = 120
            table.addTableColumn(old); table.addTableColumn(new)
        } else {
            let u = NSTableColumn(identifier: .init("u")); u.width = 1000; u.minWidth = 200
            table.addTableColumn(u)
        }
    }

    private func load() {
        let repo = self.repo, path = self.path
        DispatchQueue.global().async { [weak self] in
            let v = Git.versions(repo, path)
            let rows = computeDiff(old: v.old, new: v.new)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rows = rows
                self.unified = Self.flatten(rows)
                self.loaded = true
                self.emptyLabel.isHidden = !rows.isEmpty
                self.table.reloadData()
            }
        }
    }

    private static func flatten(_ rows: [DiffRow]) -> [UnifiedLine] {
        var out: [UnifiedLine] = []
        for row in rows {
            switch row {
            case .equal(let o, let n, let t): out.append(UnifiedLine(oldNo: o, newNo: n, sign: " ", text: t, bg: .clear, fg: diffTextFg))
            case .del(let o, let t): out.append(UnifiedLine(oldNo: o, newNo: nil, sign: "-", text: t, bg: delBg, fg: delFg))
            case .ins(let n, let t): out.append(UnifiedLine(oldNo: nil, newNo: n, sign: "+", text: t, bg: addBg, fg: addFg))
            case .change(let o, let n, let ot, let nt):
                out.append(UnifiedLine(oldNo: o, newNo: nil, sign: "-", text: ot, bg: delBg, fg: delFg))
                out.append(UnifiedLine(oldNo: nil, newNo: n, sign: "+", text: nt, bg: addBg, fg: addFg))
            }
        }
        return out
    }

    @objc private func toggleSplit() {
        split = seg.selectedSegment == 1
        UserDefaults.standard.set(split, forKey: "diffSplit")
        configureColumns()
        table.reloadData()
    }

    @objc private func openTapped() { onOpenFile() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { split ? rows.count : unified.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = DiffCellView()
        if split {
            let (old, new) = Self.sides(rows[row])
            let side = tableColumn?.identifier.rawValue == "old" ? old : new
            cell.configure(no: side.no, text: side.text, fg: side.fg, bg: side.bg)
        } else {
            let l = unified[row]
            let prefix = "\(gut(l.oldNo)) \(gut(l.newNo)) \(l.sign) "
            cell.configure(prefixedText: prefix + l.text, fg: l.fg, bg: l.bg)
        }
        return cell
    }

    private func gut(_ n: Int?) -> String {
        let s = n.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, 4 - s.count)) + s
    }

    private static func sides(_ row: DiffRow) -> (old: (no: Int?, text: String, fg: NSColor, bg: NSColor),
                                                  new: (no: Int?, text: String, fg: NSColor, bg: NSColor)) {
        switch row {
        case .equal(let o, let n, let t): return ((o, t, diffTextFg, .clear), (n, t, diffTextFg, .clear))
        case .del(let o, let t):          return ((o, t, delFg, delBg), (nil, "", diffTextFg, .clear))
        case .ins(let n, let t):          return ((nil, "", diffTextFg, .clear), (n, t, addFg, addBg))
        case .change(let o, let n, let ot, let nt): return ((o, ot, delFg, delBg), (n, nt, addFg, addBg))
        }
    }
}

/// One diff line cell: monospaced text on a full-cell background color.
private final class DiffCellView: NSView {
    private let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        field.font = diffFont()
        field.lineBreakMode = .byClipping
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(prefixedText: String, fg: NSColor, bg: NSColor) {
        field.stringValue = prefixedText.isEmpty ? " " : prefixedText
        field.textColor = fg
        layer?.backgroundColor = bg.cgColor
    }

    func configure(no: Int?, text: String, fg: NSColor, bg: NSColor) {
        let g = no.map { n -> String in let s = String(n); return String(repeating: " ", count: max(0, 4 - s.count)) + s } ?? "    "
        configure(prefixedText: "\(g)  \(text)", fg: fg, bg: bg)
    }
}
