import Foundation
import Combine

/// One open repo and its tabs. Reference type + `ObservableObject` so view controllers observe a
/// specific session; `@Published` arrays drive tab/status updates.
final class Session: ObservableObject, Identifiable {
    let id: String
    let url: String          // repo root path (absolute, standardized)
    let name: String         // last path component, shown in the SESSIONS list

    @Published var tabs: [Tab]
    @Published var activeTabID: String
    @Published var tabStatus: [String: ClaudeState] = [:]   // keyed by tab id
    @Published var gitBranch: String?                       // current branch, bridged from the RepoStore poll

    init(id: String = UUID().uuidString, url: String, tabs: [Tab] = [], activeTabID: String? = nil) {
        self.id = id
        self.url = url
        self.name = (url as NSString).lastPathComponent
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id ?? ""
    }

    /// Rolled-up status for the session dot: needs ▸ done ▸ working ▸ idle (attention states win).
    var status: ClaudeState {
        let states = tabs.compactMap { tabStatus[$0.id] }
        if states.contains(.needs) { return .needs }
        if states.contains(.done) { return .done }
        if states.contains(.working) { return .working }
        return .idle
    }

    /// You're now looking at this tab → clear its attention flag (needs / done) back to idle.
    func clearAttention(_ tabID: String) {
        if let s = tabStatus[tabID], s == .needs || s == .done { tabStatus[tabID] = .idle }
    }

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }

    // MARK: - Tabs

    @discardableResult
    func addTab(_ tab: Tab) -> Tab {
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func closeTab(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        TerminalStore.shared.close(id)   // kill the PTY if this tab had one
        tabs.remove(at: idx)
        tabStatus[id] = nil
        if activeTabID == id {
            // activate the neighbour that slid into this slot, else the last tab, else nothing
            activeTabID = tabs.indices.contains(idx) ? tabs[idx].id : (tabs.last?.id ?? "")
        }
    }

    /// Kill every PTY this session owns (called when the session itself closes).
    func killTerminals() {
        for tab in tabs { TerminalStore.shared.close(tab.id) }
    }

    func activate(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if activeTabID != id { activeTabID = id }
    }

    /// Mark a tab as shown (lazy-spawn gate flips on first view).
    func markShown(_ id: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }), !tabs[i].shown { tabs[i].shown = true }
    }

    func setDirty(_ id: String, _ dirty: Bool) {
        if let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].dirty != dirty { tabs[i].dirty = dirty }
    }

    // MARK: - Files / diffs

    func openFile(_ path: String) {
        let abs = absolute(path)
        if let existing = tabs.first(where: { $0.kind == .file && $0.path == abs }) {
            activate(existing.id); return
        }
        addTab(Tab(kind: .file, title: (abs as NSString).lastPathComponent, path: abs))
    }

    /// Open (or focus, if already open) the project Search tab for this session.
    func openSearch() {
        if let existing = tabs.first(where: { $0.kind == .search }) { activate(existing.id); return }
        addTab(Tab(kind: .search, title: "Search"))
    }

    /// `path` is repo-relative here (the diff needs it relative for `git show HEAD:<path>`).
    func openDiff(_ path: String) {
        if let existing = tabs.first(where: { $0.kind == .diff && $0.path == path }) {
            activate(existing.id); return
        }
        addTab(Tab(kind: .diff, title: (path as NSString).lastPathComponent, path: path))
    }

    // MARK: - File-tree sync (rename / delete reflected in open tabs)

    /// A file/folder was renamed on disk — retarget any open tab whose file is it, or sits inside it
    /// (folder rename). `.file` tabs store an absolute path; `.diff` tabs store a repo-relative one.
    func fileRenamed(from oldRel: String, to newRel: String) {
        let oldAbs = absolute(oldRel), newAbs = absolute(newRel)
        for i in tabs.indices {
            let (from, to): (String, String)
            switch tabs[i].kind {
            case .file: (from, to) = (oldAbs, newAbs)
            case .diff: (from, to) = (oldRel, newRel)
            default: continue
            }
            guard let p = tabs[i].path, let moved = Self.remap(p, from: from, to: to) else { continue }
            tabs[i].path = moved
            tabs[i].title = (moved as NSString).lastPathComponent
        }
    }

    /// A file/folder was deleted — close any open tab for it (or for files inside a deleted folder).
    func fileDeleted(_ rel: String) {
        let abs = absolute(rel)
        let doomed = tabs.filter { t in
            guard t.kind == .file || t.kind == .diff, let p = t.path else { return false }
            let target = t.kind == .diff ? rel : abs
            return p == target || p.hasPrefix(target + "/")
        }
        doomed.forEach { closeTab($0.id) }
    }

    /// Map a path through a rename: exact match → new; inside the renamed folder → reparent; else nil.
    private static func remap(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        if path.hasPrefix(old + "/") { return new + String(path.dropFirst(old.count)) }
        return nil
    }

    // MARK: - Reorder (drag)

    func moveTabToEnd(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs.remove(at: idx)
        tabs.append(t)
    }

    func moveTab(_ id: String, before targetID: String) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              let target = tabs.firstIndex(where: { $0.id == targetID }), from != target else { return }
        let t = tabs.remove(at: from)
        let insertAt = tabs.firstIndex(where: { $0.id == targetID }) ?? target
        tabs.insert(t, at: insertAt)
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (url as NSString).appendingPathComponent(path)
    }
}
