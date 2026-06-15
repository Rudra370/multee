import AppKit

/// Global hook so ⌘P (an AppDelegate menu item) can reach the single palette owned by the window
/// controller — same static-hook pattern as `FormatterInstall` / `ActiveEditor`.
enum CommandPaletteHook {
    static var toggle: (() -> Void)?          // ⌘P — file quick-open
    static var command: (() -> Void)?         // ⌘⇧P — command mode
}

/// VS Code-style quick-open (⌘P): a top-centered overlay with a search field over a results list.
/// Type to fuzzy-match files in the active session's repo, ↑/↓ to move, Enter to open, Esc / click-out
/// to dismiss. Empty query lists the currently-open file tabs (quick switch). The file list is fetched
/// once per open via `Git.repoFiles` (off-main, gitignored dirs excluded) — no extra git poller, so it
/// costs nothing until you press ⌘P.
final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static weak var current: CommandPaletteController?

    private let model: AppModel
    private weak var host: NSView?

    private struct Row { let rel: String; let status: GitStatus }
    private struct PaletteCommand { let title: String; let keepsOpen: Bool; let run: () -> Void }
    private enum Mode { case file, line, command }

    private var allRows: [Row] = []        // full repo listing (lazy, fetched on present)
    private var openRows: [Row] = []       // currently-open file tabs (shown for empty query)
    private var hits: [Row] = []           // current filtered/sorted file results
    private var commandHits: [PaletteCommand] = []   // filtered commands (`>` mode)
    private var commandQuery = ""          // the text after `>` (for match highlighting)
    private var mode: Mode = .file
    private var lineJump: Int?             // set when the query is `:123` (jump in the active editor)
    private var selected = 0
    private var resultCount: Int { mode == .command ? commandHits.count : hits.count }
    private var loadToken = 0              // drops a stale async listing if the palette was reopened

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Remember where to mount the overlay (added only on present, removed on dismiss → zero idle cost).
    func attach(to host: NSView) { self.host = host }

    var isShown: Bool { overlay?.superview != nil }

    func toggle() { isShown ? dismiss() : present() }

    /// ⌘⇧P — open straight into command mode (or toggle off if already there).
    func toggleCommand() {
        if isShown && mode == .command { dismiss(); return }
        if !isShown { present() }
        field.stringValue = "> "
        selected = 0
        applyFilter()
        host?.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    // MARK: - Present / dismiss

    private var overlay: ScrimView?
    private let panel = NSView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!

    private func present() {
        guard let host, let session = model.activeSession else { return }
        CommandPaletteController.current = self

        if overlay == nil { buildUI() }
        guard let overlay else { return }

        // Seed the open-tabs quick-switch list, then fetch the full repo listing.
        openRows = session.tabs
            .filter { $0.kind == .file }
            .compactMap { $0.path }
            .map { Row(rel: relative($0, to: session.url), status: .none) }
        allRows = []
        loadFiles(repo: session.url)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        field.stringValue = ""
        selected = 0
        applyFilter()
        host.window?.makeFirstResponder(field)
    }

    func dismiss() {
        overlay?.removeFromSuperview()
        loadToken += 1   // ignore any in-flight listing
    }

    private func loadFiles(repo: String) {
        loadToken += 1
        let token = loadToken
        DispatchQueue.global().async { [weak self] in
            let rows = Git.repoFiles(repo, expandIgnored: false)
                .filter { !$0.isDir }
                .map { Row(rel: $0.path, status: $0.status) }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }   // reopened → drop stale result
                self.allRows = rows
                self.applyFilter()
            }
        }
    }

    // MARK: - Filtering

    private func applyFilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        lineJump = nil; hits = []; commandHits = []; commandQuery = ""
        if query.hasPrefix(">") {
            // Command mode (`>`): run an action instead of opening a file.
            mode = .command
            commandQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            let cmds = buildCommands()
            commandHits = commandQuery.isEmpty ? cmds
                : cmds.compactMap { c in Fuzzy.score(commandQuery, c.title).map { (c, $0) } }
                       .sorted { $0.1 > $1.1 }.map { $0.0 }
        } else if query.hasPrefix(":") {
            // Line-jump mode (`:123`): no file results — Enter jumps in the active editor.
            mode = .line
            let digits = query.dropFirst().filter(\.isNumber)
            lineJump = digits.isEmpty ? nil : Int(digits)
        } else if query.isEmpty {
            mode = .file
            hits = openRows
        } else {
            mode = .file
            hits = allRows
                .compactMap { row -> (Row, Int)? in Fuzzy.score(query, row.rel).map { (row, $0) } }
                .sorted {
                    $0.1 != $1.1 ? $0.1 > $1.1
                        : ($0.0.rel.count != $1.0.rel.count ? $0.0.rel.count < $1.0.rel.count
                           : $0.0.rel < $1.0.rel)
                }
                .prefix(50)
                .map { $0.0 }
        }
        selected = min(selected, max(0, resultCount - 1))
        table.reloadData()
        if resultCount > 0 { table.selectRowIndexes([selected], byExtendingSelection: false) }

        let rows = max(1, min(resultCount, 12))
        listHeight.constant = CGFloat(rows) * rowHeight
        placeholder.isHidden = resultCount > 0
        placeholder.stringValue = placeholderText(query)

        // Resolve the panel→scroll resize synchronously and re-tile the table to its new clip — otherwise
        // the scroll/table frames lag the constant change for a frame (a shrinking list paints a stretched
        // selection until the next pass).
        overlay?.layoutSubtreeIfNeeded()
        table.tile()
    }

    private func placeholderText(_ query: String) -> String {
        switch mode {
        case .command: return "No matching commands"
        case .line: return ActiveEditor.current == nil ? "Open a file first"
            : lineJump == nil ? "Type a line number" : "Go to line \(lineJump!)  ⏎"
        case .file: return query.isEmpty ? "No open files" : "No matching files"
        }
    }

    /// Actions for command mode, built fresh each filter so availability tracks current state (e.g. New
    /// Claude only with a session, Format only with an editor open).
    private func buildCommands() -> [PaletteCommand] {
        var c: [PaletteCommand] = []
        if let s = model.activeSession {
            c.append(PaletteCommand(title: "New Claude Session", keepsOpen: false) { [weak self] in
                s.addTab(Tab(kind: .claude, title: "Claude", args: self?.model.settings.defaultArgs ?? ""))
            })
            c.append(PaletteCommand(title: "New Terminal", keepsOpen: false) {
                s.addTab(Tab(kind: .terminal, title: "Terminal"))
            })
        }
        if ActiveEditor.current != nil {
            c.append(PaletteCommand(title: "Format Document", keepsOpen: false) {
                ActiveEditor.current?.formatDocument()
            })
        }
        c.append(PaletteCommand(title: "Go to File…", keepsOpen: true) { [weak self] in self?.enterFileMode() })
        c.append(PaletteCommand(title: "Settings…", keepsOpen: false) { [weak self] in self?.model.showSettings = true })
        if let s = model.activeSession, let t = s.activeTab {
            c.append(PaletteCommand(title: "Close Tab", keepsOpen: false) {
                if UnsavedGuard.confirmClose(t) { s.closeTab(t.id) }
            })
        }
        return c
    }

    /// Switch back to file search from command mode (the "Go to File…" command).
    private func enterFileMode() {
        field.stringValue = ""
        selected = 0
        applyFilter()
        host?.window?.makeFirstResponder(field)
    }

    private func move(_ delta: Int) {
        guard resultCount > 0 else { return }
        selected = max(0, min(resultCount - 1, selected + delta))
        table.selectRowIndexes([selected], byExtendingSelection: false)
        table.scrollRowToVisible(selected)
    }

    private func openSelected() {
        switch mode {
        case .line:
            if let line = lineJump, let editor = ActiveEditor.current { dismiss(); editor.goToLine(line) }
        case .command:
            guard commandHits.indices.contains(selected) else { return }
            let cmd = commandHits[selected]
            if cmd.keepsOpen { cmd.run() } else { dismiss(); cmd.run() }   // Go to File… stays open
        case .file:
            guard hits.indices.contains(selected) else { return }
            let rel = hits[selected].rel
            dismiss()
            model.activeSession?.openFile(rel)
        }
    }

    // MARK: - NSControlTextEditingDelegate (drive the list from the field)

    func controlTextDidChange(_ obj: Notification) {
        selected = 0
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):       move(1); return true
        case #selector(NSResponder.moveUp(_:)):         move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):  openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    // MARK: - Table

    private let rowHeight: CGFloat = 32

    func numberOfRows(in tableView: NSTableView) -> Int { resultCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("paletteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaletteCellView) ?? {
            let c = PaletteCellView(); c.identifier = id; return c
        }()
        if mode == .command {
            let cmd = commandHits[row]
            cell.configure(name: cmd.title, dir: "", status: .none,
                           nameMatches: Fuzzy.matches(commandQuery, cmd.title), dirMatches: [])
            return cell
        }
        let r = hits[row]
        let name = (r.rel as NSString).lastPathComponent
        let dir = (r.rel as NSString).deletingLastPathComponent
        // Map the full-path match positions onto the name (after the last "/") and dir segments so each
        // field bolds its own matched chars. The char at baseStart-1 is the "/" separator (never bolded).
        let baseStart = r.rel.count - name.count
        var nameMatches: [Int] = [], dirMatches: [Int] = []
        for m in Fuzzy.matches(field.stringValue.trimmingCharacters(in: .whitespaces), r.rel) {
            if m >= baseStart { nameMatches.append(m - baseStart) }
            else if m < baseStart - 1 { dirMatches.append(m) }
        }
        cell.configure(name: name, dir: dir, status: r.status,
                       nameMatches: nameMatches, dirMatches: dirMatches)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        selected = table.clickedRow
        openSelected()
    }

    // MARK: - UI build

    private func buildUI() {
        let overlay = ScrimView()
        overlay.wantsLayer = true
        overlay.onClickOutside = { [weak self] point in
            guard let self else { return }
            if !self.panel.frame.contains(point) { self.dismiss() }
        }

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(white: 0.30, alpha: 1).cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = .black
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 16
        panel.layer?.shadowOffset = CGSize(width: 0, height: -4)
        overlay.addSubview(panel)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = NSColor(white: 0.95, alpha: 1)
        field.placeholderString = "Search files by name"
        field.delegate = self
        panel.addSubview(field)

        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.30, alpha: 1).cgColor
        panel.addSubview(sep)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.backgroundColor = .clear
        // `.automatic` (the default on macOS 11+) inset-pads rows and draws a rounded, inset selection —
        // which stretched our single-row selection band. `.plain` = exact row height, full-width selection.
        if #available(macOS 11.0, *) { table.style = .plain }
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        panel.addSubview(scroll)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = NSColor(white: 0.5, alpha: 1)
        placeholder.alignment = .center
        // On the panel (above the scroll), not inside it — NSScrollView clips/hides directly-added subviews.
        panel.addSubview(placeholder)

        listHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 80),
            panel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: 560),

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -4),
            listHeight,

            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.overlay = overlay
    }

    private func relative(_ abs: String, to repo: String) -> String {
        let prefix = repo.hasSuffix("/") ? repo : repo + "/"
        return abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : (abs as NSString).lastPathComponent
    }

    // MARK: - Debug harness hooks (HID can't drive ⌘P / arrows in the sandbox)

    func debugType(_ text: String) { field.stringValue = text; selected = 0; applyFilter() }
    func debugMove(_ delta: Int) { move(delta) }
    func debugOpenSelected() { openSelected() }
    func debugState() -> [String: Any] {
        let label: Any = mode == .command
            ? (commandHits.indices.contains(selected) ? commandHits[selected].title as Any : NSNull())
            : (hits.indices.contains(selected) ? hits[selected].rel as Any : NSNull())
        return ["shown": isShown, "query": field.stringValue, "mode": "\(mode)",
                "results": resultCount, "selected": selected, "selectedPath": label]
    }
}

/// Full-host click catcher: a click outside the panel dismisses (handled by the controller).
private final class ScrimView: NSView {
    var onClickOutside: ((NSPoint) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClickOutside?(convert(event.locationInWindow, from: nil))
    }
}

/// One result row: filename (git-status tinted) + a dim parent dir, vertically centered. Colors brighten
/// when selected so the dim dir text stays legible on the accent-blue background (`backgroundStyle`
/// flips to `.emphasized`, driven by the row view's `interiorBackgroundStyle` below).
private final class PaletteCellView: NSTableCellView {
    private let nameField = NSTextField(labelWithString: "")
    private let dirField = NSTextField(labelWithString: "")
    private var status: GitStatus = .none
    private var name = "", dir = ""
    private var nameMatches: Set<Int> = [], dirMatches: Set<Int> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [nameField, dirField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, dir: String, status: GitStatus, nameMatches: [Int], dirMatches: [Int]) {
        self.name = name; self.dir = dir; self.status = status
        self.nameMatches = Set(nameMatches); self.dirMatches = Set(dirMatches)
        dirField.isHidden = dir.isEmpty
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    /// Rebuilds both labels' attributed text: base color from selection + git status, with matched chars
    /// brightened and bold. Re-run on selection change so the highlight tracks the accent background.
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        nameField.attributedStringValue = styled(name, size: 13, truncate: .byTruncatingTail,
            base: selected ? NSColor(white: 1, alpha: 0.85) : nsStatusColor(status),
            match: .white, matches: nameMatches)
        dirField.attributedStringValue = styled(dir, size: 11, truncate: .byTruncatingMiddle,
            base: selected ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0.5, alpha: 1),
            match: selected ? .white : NSColor(white: 0.85, alpha: 1), matches: dirMatches)
    }

    private func styled(_ s: String, size: CGFloat, truncate: NSLineBreakMode,
                        base: NSColor, match: NSColor, matches: Set<Int>) -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = truncate
        let a = NSMutableAttributedString(string: s, attributes: [
            .foregroundColor: base, .font: NSFont.systemFont(ofSize: size), .paragraphStyle: para,
        ])
        if !matches.isEmpty {
            let bold = NSFont.systemFont(ofSize: size, weight: .bold)
            var u16 = 0   // matched indices are Character offsets; map each to its UTF-16 range
            for (ci, ch) in s.enumerated() {
                let len = String(ch).utf16.count
                if matches.contains(ci) {
                    a.addAttributes([.font: bold, .foregroundColor: match],
                                    range: NSRange(location: u16, length: len))
                }
                u16 += len
            }
        }
        return a
    }
}

/// Accent-tinted selection that fills the row (and forces `.emphasized` so cell text brightens even when
/// the window isn't key — e.g. while the harness drives it).
private final class PaletteRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        bounds.fill()
    }
}

// MARK: - Fuzzy scoring

enum Fuzzy {
    /// Subsequence match of `query` in `candidate` (case-insensitive). Returns nil if not all query
    /// chars appear in order; otherwise a score where higher = better. Bonuses: consecutive runs,
    /// word-boundary / camelCase starts, and matches in the filename (last path component). Greedy
    /// earliest-match — complete for detecting a subsequence, good-enough for ranking.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased())
        if q.isEmpty { return 0 }
        let orig = Array(candidate)
        let lower = Array(candidate.lowercased())
        let baseStart = lower.count - ((candidate as NSString).lastPathComponent.count)

        var qi = 0, total = 0, prevMatch = -2, i = 0
        while i < lower.count && qi < q.count {
            if lower[i] == q[qi] {
                var s = 1
                if i == prevMatch + 1 { s += 5 }                                   // consecutive
                let prev: Character = i > 0 ? orig[i - 1] : "/"
                if "/._- ".contains(prev) { s += 8 }                               // word boundary
                else if orig[i].isUppercase && !orig[i - 1].isUppercase { s += 4 } // camelCase
                if i >= baseStart { s += 3 }                                       // filename region
                total += s
                prevMatch = i
                qi += 1
            }
            i += 1
        }
        guard qi == q.count else { return nil }
        return total - lower.count / 40   // mild preference for shorter paths
    }

    /// The character indices `query` matches in `candidate` (same greedy earliest-match as `score`, so the
    /// highlighted chars are exactly the ones that earned the score). Empty if not a full subsequence.
    static func matches(_ query: String, _ candidate: String) -> [Int] {
        let q = Array(query.lowercased())
        if q.isEmpty { return [] }
        let lower = Array(candidate.lowercased())
        var qi = 0, out: [Int] = [], i = 0
        while i < lower.count && qi < q.count {
            if lower[i] == q[qi] { out.append(i); qi += 1 }
            i += 1
        }
        return qi == q.count ? out : []
    }
}
