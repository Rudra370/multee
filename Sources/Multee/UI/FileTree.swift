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
/// preserving expansion across reloads by path. Right-click menu (NSMenuDelegate) does
/// rename (inline, reusing the draft-field machinery) / delete (→ Trash) / new file / new folder /
/// copy path / copy relative path, contextual to the clicked row.
final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let store: RepoStore
    private let settings: Settings
    private let onOpen: (String) -> Void

    private let outline = PointerOutlineView()   // pointing-hand cursor over rows
    private let scroll = NSScrollView()
    private var roots: [TreeNode] = []
    private var expandedPaths = Set<String>()
    private var restoring = false
    private var cancellables = Set<AnyCancellable>()

    // Inline create / rename — named in-tree like VS Code.
    private enum EditKind { case newFile, newFolder, rename }
    private var editKind: EditKind?
    private var editingNode: TreeNode?              // the draft (create) or existing (rename) node being edited
    private var draftParentId = ""                  // repo-relative folder the draft lives in ("" = root)
    private var renameOriginalId = ""               // original repo-relative path being renamed
    private var editCancelled = false
    private var menuTargetNode: TreeNode?           // the row a context-menu action operates on
    private var pendingFiles: [FileEntry]?          // file updates that arrived mid-edit; applied on end
    private var pendingEmptyDirs = Set<String>()    // just-made empty folders (git omits empty dirs)
    private var isEditing: Bool { editingNode != nil }
    private static let draftId = "\u{1}draft"

    /// The live tree VC (for the dev harness to drive). Only one is mounted at a time.
    static weak var current: FileTreeViewController?

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
        // Don't widen the outline column to fit indentation on expand — it pushes the view's frame past
        // the clip width, which shrinks row/selection width and leaves the pointing-hand cursor stale
        // (row(at:) over the now-oversized frame). Keep the frame == clip width at every depth.
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = NSColor(white: 0.145, alpha: 1)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.autoresizingMask = [.width, .height]
        let menu = NSMenu()
        menu.delegate = self        // rebuilt per right-clicked row in menuNeedsUpdate
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.145, alpha: 1)
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.current = self
        loadEmptyDirs()   // restore user-made empty folders before the first tree build
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
        // Don't rebuild under an active inline edit — it would yank the draft row out. Stash and apply
        // once editing ends.
        if isEditing { pendingFiles = files; return }
        // git omits empty dirs, so a just-created empty folder isn't in `files`. Keep injecting it until
        // it actually contains a file (then git lists it) or it's deleted.
        let before = pendingEmptyDirs
        pendingEmptyDirs = pendingEmptyDirs.filter { dir in
            FileManager.default.fileExists(atPath: (store.repo as NSString).appendingPathComponent(dir))
                && !files.contains { $0.path == dir || $0.path.hasPrefix(dir + "/") }
        }
        if pendingEmptyDirs != before { persistEmptyDirs() }   // a folder gained files or vanished
        let emptyDirs = pendingEmptyDirs
        let augmented = emptyDirs.isEmpty ? files
            : files + emptyDirs.map { FileEntry(path: $0, status: .none, isDir: true) }   // empty folder: neutral, not green
        DispatchQueue.global().async { [weak self] in
            let tree = buildTree(augmented)
            for dir in emptyDirs { Self.markEmptyFolder(dir, in: tree) }   // leaf → expandable empty folder
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

    /// A synthetic empty dir builds as an `isDir` *leaf*; give it `children = []` so it shows as a real
    /// (expandable, empty) folder you can drop files into, not a dead "name/" row.
    private static func markEmptyFolder(_ id: String, in nodes: [TreeNode]) {
        for n in nodes {
            if n.id == id { if n.children == nil { n.children = [] }; return }
            if let c = n.children, !c.isEmpty { markEmptyFolder(id, in: c) }
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

    // MARK: Toolbar actions (collapse-all + inline new file/folder)

    /// Close every expanded folder, back to the just-opened state (VS Code's "Collapse Folders").
    func collapseAll() {
        restoring = true
        outline.collapseItem(nil, collapseChildren: true)   // nil = all top-level items + descendants
        expandedPaths.removeAll()
        restoring = false
        outline.window?.invalidateCursorRects(for: outline)   // refresh cursor rects for the new row set
    }

    func beginNewFile()   { beginCreate(.newFile, parent: targetFolder()) }
    func beginNewFolder() { beginCreate(.newFolder, parent: targetFolder()) }

    /// Dev-harness hook: run the inline create end-to-end (begin → name → commit) without a keyboard.
    func debugCreate(name: String, folder: Bool) {
        beginCreate(folder ? .newFolder : .newFile, parent: targetFolder())
        finishEditing(name: name)
    }

    /// Dev-harness hooks for the context-menu mutations (right-click can't be synthesized).
    func debugRename(rel: String, to newName: String) {
        guard let node = findNode(rel, in: roots) else { return }
        beginRename(node); finishEditing(name: newName)
    }
    func debugDelete(rel: String) {   // skips the confirm sheet; exercises the same trash + cleanup
        guard let node = findNode(rel, in: roots) else { return }
        let abs = (store.repo as NSString).appendingPathComponent(node.id)
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: abs), resultingItemURL: nil)
        expandedPaths.remove(node.id)
        if pendingEmptyDirs.remove(node.id) != nil { persistEmptyDirs() }
        store.refreshNow()
    }

    /// Dev-harness hook: expand every folder (to then verify collapse-all closes them).
    func debugExpandAll() {
        restoring = true
        outline.expandItem(nil, expandChildren: true)
        restoring = false
        for row in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: row) as? TreeNode, n.isFolder { expandedPaths.insert(n.id) }
        }
    }

    /// Insert an empty draft row in the given folder (nil = root) and start inline editing it.
    private func beginCreate(_ kind: EditKind, parent: TreeNode?) {
        guard editingNode == nil else { return }   // one edit at a time
        if let parent, !outline.isItemExpanded(parent) {
            restoring = true; outline.expandItem(parent); restoring = false
            expandedPaths.insert(parent.id)
        }
        draftParentId = parent?.id ?? ""
        let draft = TreeNode(id: Self.draftId, name: "", status: .new, isDir: false, children: nil)
        if let parent { parent.children?.insert(draft, at: 0) } else { roots.insert(draft, at: 0) }
        editKind = kind
        editingNode = draft
        editCancelled = false
        if let parent { outline.reloadItem(parent, reloadChildren: true) } else { outline.reloadData() }
        beginFieldEditing(for: draft)
    }

    /// Where a new item goes: the selected folder, the selected file's folder, else the repo root.
    private func targetFolder() -> TreeNode? {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? TreeNode else { return nil }
        if node.isFolder { return node }
        let parentId = (node.id as NSString).deletingLastPathComponent
        return parentId.isEmpty ? nil : findNode(parentId, in: roots)
    }

    private func findNode(_ id: String, in nodes: [TreeNode]) -> TreeNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let f = findNode(id, in: c) { return f }
        }
        return nil
    }

    // MARK: Context menu (right-click)

    /// Rebuild the menu for the right-clicked row (`clickedRow`); empty space → root create actions.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outline.clickedRow
        menuTargetNode = (row >= 0) ? outline.item(atRow: row) as? TreeNode : nil
        menu.items = contextItems(for: menuTargetNode)
    }

    /// Pure builder (also drives the dev-harness menu assertion).
    func contextItems(for node: TreeNode?) -> [NSMenuItem] {
        func item(_ title: String, _ sel: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
        }
        guard let node else {   // empty space
            return [item("New File", #selector(ctxNewFile)), item("New Folder", #selector(ctxNewFolder))]
        }
        let copy = [item("Copy Path", #selector(ctxCopyPath)), item("Copy Relative Path", #selector(ctxCopyRelative))]
        let edit = [item("Rename", #selector(ctxRename)), item("Delete", #selector(ctxDelete))]
        if node.isFolder {
            return [item("New File", #selector(ctxNewFile)), item("New Folder", #selector(ctxNewFolder)),
                    .separator()] + edit + [.separator()] + copy
        }
        return edit + [.separator()] + copy + [.separator(),
                item("New File", #selector(ctxNewFile)), item("New Folder", #selector(ctxNewFolder))]
    }

    /// Folder a context-menu create should target: the clicked folder, the clicked file's folder, else root.
    private func contextParent() -> TreeNode? {
        // Resolve the live node by id (the menu's node object can be stale if the tree refreshed while
        // the menu was open); fall back to root if it's gone.
        guard let target = menuTargetNode, let node = findNode(target.id, in: roots) else { return nil }
        if node.isFolder { return node }
        let parentId = (node.id as NSString).deletingLastPathComponent
        return parentId.isEmpty ? nil : findNode(parentId, in: roots)
    }

    @objc private func ctxNewFile()   { beginCreate(.newFile, parent: contextParent()) }
    @objc private func ctxNewFolder() { beginCreate(.newFolder, parent: contextParent()) }
    @objc private func ctxRename()    { if let n = menuTargetNode { beginRename(n) } }
    @objc private func ctxDelete()    { if let n = menuTargetNode { confirmDelete(n) } }
    @objc private func ctxCopyPath()  { if let n = menuTargetNode { Clipboard.copy((store.repo as NSString).appendingPathComponent(n.id)) } }
    @objc private func ctxCopyRelative() { if let n = menuTargetNode { Clipboard.copy(n.id) } }

    /// Inline-rename an existing row (reuses the draft-field machinery; the node stays in place).
    private func beginRename(_ node: TreeNode) {
        // Resolve the live node by id — the menu's node object may be stale after a refresh.
        guard editingNode == nil, !node.id.isEmpty, let live = findNode(node.id, in: roots) else { return }
        editKind = .rename
        editingNode = live
        renameOriginalId = live.id
        editCancelled = false
        outline.reloadItem(live)        // re-render the row as an editable field
        beginFieldEditing(for: live)
    }

    private func confirmDelete(_ node: TreeNode) {
        guard !node.id.isEmpty, let window = outline.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(node.name)”?"
        alert.informativeText = "It will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let abs = (self.store.repo as NSString).appendingPathComponent(node.id)
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: abs), resultingItemURL: nil)
            self.expandedPaths.remove(node.id)
            if self.pendingEmptyDirs.remove(node.id) != nil { self.persistEmptyDirs() }
            self.store.refreshNow()
        }
    }

    /// Focus the row's text field so the user can type the name immediately.
    private func beginFieldEditing(for node: TreeNode) {
        let row = outline.row(forItem: node)
        if row >= 0,
           let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
           let field = cell.textField {
            outline.scrollRowToVisible(row)
            outline.window?.makeFirstResponder(field)
            return
        }
        // Couldn't start the inline edit (row not realizable) — reset so we don't get stuck in edit state.
        let wasDraft = editingNode?.id == Self.draftId
        editingNode = nil; editKind = nil; editCancelled = false
        if wasDraft { removeNode(node) }
        reloadAfterEdit()
    }

    // Commit on Return / focus-loss; cancel on Escape.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editCancelled = true
            outline.window?.makeFirstResponder(outline)   // ends editing → controlTextDidEndEditing
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard isEditing, let field = note.object as? NSTextField else { return }
        finishEditing(name: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func finishEditing(name: String) {
        guard let kind = editKind, let node = editingNode else { return }
        let cancelled = editCancelled
        editingNode = nil; editKind = nil; editCancelled = false   // clear first — this can re-enter
        defer { reloadAfterEdit() }

        switch kind {
        case .rename:
            // The edited row is a real node; only act if the name actually changed and is valid.
            guard !cancelled, isValidName(name), name != node.name else { return }
            renameCommit(to: name)
        case .newFile, .newFolder:
            removeNode(node)   // drop the draft; a real node arrives via the refresh below
            guard !cancelled, isValidName(name) else { return }
            createCommit(kind, name: name)
        }
    }

    private func createCommit(_ kind: EditKind, name: String) {
        let rel = draftParentId.isEmpty ? name : draftParentId + "/" + name
        let abs = (store.repo as NSString).appendingPathComponent(rel)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: abs) else { warn("“\(name)” already exists."); return }

        if kind == .newFolder {
            try? fm.createDirectory(atPath: abs, withIntermediateDirectories: true)
            pendingEmptyDirs.insert(rel)
            persistEmptyDirs()
        } else {
            // "folder/file.txt" → create the intervening folders, then the file.
            try? fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: abs, contents: nil)
        }
        store.refreshNow()
        if kind == .newFile { onOpen(rel) }
    }

    private func renameCommit(to name: String) {
        // Rename keeps the item in place; only its last path component changes.
        let parentId = (renameOriginalId as NSString).deletingLastPathComponent
        let destRel = parentId.isEmpty ? name : parentId + "/" + name
        guard destRel != renameOriginalId else { return }
        let fm = FileManager.default
        let src = (store.repo as NSString).appendingPathComponent(renameOriginalId)
        let dst = (store.repo as NSString).appendingPathComponent(destRel)
        guard !fm.fileExists(atPath: dst) else { warn("“\(name)” already exists."); return }
        do {
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: src, toPath: dst)
        } catch {
            warn("Couldn't rename: \(error.localizedDescription)"); return
        }
        remapPaths(from: renameOriginalId, to: destRel)   // keep expansion / empty-dir state across the rename
        store.refreshNow()
    }

    /// Rewrite saved paths (expanded folders, tracked empty dirs) after a rename so a renamed folder
    /// keeps its expanded state and its descendants stay consistent.
    private func remapPaths(from old: String, to new: String) {
        func remap(_ s: String) -> String {
            if s == old { return new }
            if s.hasPrefix(old + "/") { return new + s.dropFirst(old.count) }
            return s
        }
        expandedPaths = Set(expandedPaths.map(remap))
        if !pendingEmptyDirs.isEmpty { pendingEmptyDirs = Set(pendingEmptyDirs.map(remap)); persistEmptyDirs() }
    }

    /// Accepts slash-separated paths ("folder/file.txt"); every component must be a real name.
    private func isValidName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func warn(_ msg: String) {
        guard let window = outline.window else { return }
        let alert = NSAlert(); alert.messageText = msg; alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func removeNode(_ node: TreeNode) {
        func rm(_ arr: inout [TreeNode]) -> Bool {
            if let i = arr.firstIndex(where: { $0 === node }) { arr.remove(at: i); return true }
            for n in arr { if var c = n.children, rm(&c) { n.children = c; return true } }
            return false
        }
        _ = rm(&roots)
    }

    // Empty user-made folders aren't in git, so we remember them per-repo to survive relaunch (filtered
    // on load to ones that still exist on disk and are still empty).
    private var emptyDirsKey: String { "multee.emptyDirs:" + store.repo }

    private func loadEmptyDirs() {
        let saved = (UserDefaults.standard.array(forKey: emptyDirsKey) as? [String]) ?? []
        pendingEmptyDirs = Set(saved.filter { dir in
            var isDir: ObjCBool = false
            let abs = (store.repo as NSString).appendingPathComponent(dir)
            return FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) && isDir.boolValue
        })
    }

    private func persistEmptyDirs() {
        if pendingEmptyDirs.isEmpty { UserDefaults.standard.removeObject(forKey: emptyDirsKey) }
        else { UserDefaults.standard.set(Array(pendingEmptyDirs), forKey: emptyDirsKey) }
    }

    /// After an edit ends: redraw without the draft, then flush any file update that arrived mid-edit.
    private func reloadAfterEdit() {
        restoring = true
        outline.reloadData()
        restoreExpansion(roots)
        restoring = false
        if let files = pendingFiles { pendingFiles = nil; applyFiles(files) }
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

        // Draft row being named inline: editable field, no status styling.
        if node === editingNode, let field = cell.textField {
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            field.drawsBackground = true
            field.backgroundColor = NSColor(white: 0.22, alpha: 1)
            field.isBordered = true
            field.textColor = NSColor(white: 0.96, alpha: 1)
            field.stringValue = node.name
            field.placeholderString = editKind == .newFolder ? "Folder name" : "File name"
            return cell
        }
        if let field = cell.textField {   // reset reused cells back to plain-label state
            field.isEditable = false; field.isSelectable = false; field.delegate = nil
            field.drawsBackground = false; field.isBordered = false; field.placeholderString = nil
        }

        let title = node.name + ((node.isDir && !node.isFolder) ? "/" : "")   // slash only for collapsed leaf dirs
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
