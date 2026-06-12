import AppKit
import Combine

// MARK: - Tree model (pure; shared with the old build)

final class TreeNode {
    let id: String        // repo-relative path
    let name: String
    var status: GitStatus
    let isDir: Bool       // collapsed dir (e.g. ignored) with no children
    var children: [TreeNode]?
    init(id: String, name: String, status: GitStatus, isDir: Bool, children: [TreeNode]?) {
        self.id = id; self.name = name; self.status = status; self.isDir = isDir; self.children = children
    }
    var isFolder: Bool { children != nil }
}

private let priority: [GitStatus] = [.conflict, .deleted, .modified, .renamed, .new]

func buildTree(_ entries: [FileEntry]) -> [TreeNode] {
    let root = TreeNode(id: "", name: "", status: .none, isDir: false, children: [])
    var dirs: [String: TreeNode] = ["": root]

    for e in entries {
        let parts = e.path.split(separator: "/").map(String.init)
        var parent = root
        var prefix = ""
        for (i, name) in parts.enumerated() {
            let cur = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if i == parts.count - 1 {
                let leaf = TreeNode(id: cur, name: name, status: e.status, isDir: e.isDir, children: nil)
                parent.children?.append(leaf)
            } else {
                if let d = dirs[cur] {
                    parent = d
                } else {
                    let d = TreeNode(id: cur, name: name, status: .none, isDir: false, children: [])
                    dirs[cur] = d
                    parent.children?.append(d)
                    parent = d
                }
                prefix = cur
            }
        }
    }

    func agg(_ node: TreeNode) -> GitStatus {
        guard node.isFolder else { return (node.status == .ignored || node.status == .none) ? .none : node.status }
        var best: GitStatus = .none
        for ch in node.children ?? [] {
            let s = agg(ch)
            if s != .none, best == .none || priority.firstIndex(of: s)! < priority.firstIndex(of: best)! {
                best = s
            }
        }
        node.status = best
        return best
    }
    func sort(_ node: TreeNode) {
        node.children?.sort { a, b in
            let da = a.isFolder || a.isDir, db = b.isFolder || b.isDir
            return da != db ? da : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        node.children?.forEach(sort)
    }
    root.children?.forEach { _ = agg($0) }
    sort(root)
    return root.children ?? []
}

func nsStatusColor(_ s: GitStatus) -> NSColor {
    switch s {
    case .none:            return NSColor(white: 0.80, alpha: 1)
    case .new, .renamed:   return NSColor(red: 0.45, green: 0.79, blue: 0.57, alpha: 1)
    case .modified:        return NSColor(red: 0.89, green: 0.75, blue: 0.55, alpha: 1)
    case .deleted:         return NSColor(red: 0.78, green: 0.31, blue: 0.22, alpha: 1)
    case .conflict:        return NSColor(red: 0.89, green: 0.40, blue: 0.42, alpha: 1)
    case .ignored:         return NSColor(white: 0.43, alpha: 1)
    }
}

// MARK: - File tree view controller (NSOutlineView)

/// One repo's file tree. NSOutlineView gives native disclosure, row virtualization, and correct
/// cursors. Polls git every 1.5s; only reloads when the visible set actually changes (signature),
/// preserving expansion across reloads by path.
final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let store: RepoStore
    private let settings: Settings
    private let onOpen: (String) -> Void

    private let outline = PointerOutlineView()   // pointing-hand cursor over rows
    private let scroll = NSScrollView()
    private var roots: [TreeNode] = []
    private var expandedPaths = Set<String>()
    private var restoring = false
    private var cancellables = Set<AnyCancellable>()

    init(store: RepoStore, settings: Settings, onOpen: @escaping (String) -> Void) {
        self.store = store
        self.settings = settings
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = settings.fontSize + 9
        outline.indentationPerLevel = 12
        outline.backgroundColor = NSColor(white: 0.145, alpha: 1)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.autoresizingMask = [.width, .height]

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.145, alpha: 1)
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The shared RepoStore owns the watcher + git poll; we just rebuild the tree when it publishes
        // a new file set (it only publishes on a real change). Expand-ignored re-polls happen there too.
        store.$files
            .sink { [weak self] files in self?.applyFiles(files) }
            .store(in: &cancellables)
        settings.$fontSize
            .dropFirst()
            .sink { [weak self] size in
                guard let self else { return }
                self.outline.rowHeight = size + 9
                self.outline.reloadData()
                self.restoreExpansion(self.roots)
            }
            .store(in: &cancellables)
    }

    /// Build the tree off-main (the store already gated the publish to real changes), then reload and
    /// re-expand on main.
    private func applyFiles(_ files: [FileEntry]) {
        DispatchQueue.global().async { [weak self] in
            let tree = buildTree(files)
            DispatchQueue.main.async {
                guard let self else { return }
                self.roots = tree
                self.restoring = true
                self.outline.reloadData()
                self.restoreExpansion(self.roots)
                self.restoring = false
            }
        }
    }

    /// Re-expand only branches that are actually expanded — don't walk the whole (possibly huge)
    /// tree on the main thread, which froze opening large repos.
    private func restoreExpansion(_ nodes: [TreeNode]) {
        for n in nodes where n.isFolder && expandedPaths.contains(n.id) {
            outline.expandItem(n)
            restoreExpansion(n.children ?? [])
        }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if !node.isDir {
            onOpen(node.id)
        }
    }

    // MARK: Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? TreeNode)?.children?.count ?? (item == nil ? roots.count : 0)
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TreeNode { return node.children![index] }
        return roots[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any?) -> Bool {
        (item as? TreeNode)?.isFolder ?? false
    }

    // MARK: Delegate

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (ov.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 13)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.font = .systemFont(ofSize: settings.fontSize)
        let title = node.name + (node.isDir ? "/" : "")
        let color = nsStatusColor(node.status)
        if node.status == .deleted {
            cell.textField?.attributedStringValue = NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ])
        } else {
            cell.textField?.stringValue = title
            cell.textField?.textColor = color
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        expandedPaths.insert(node.id)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        expandedPaths.remove(node.id)
    }
}
