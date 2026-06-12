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

    init(id: String = UUID().uuidString, url: String, tabs: [Tab] = [], activeTabID: String? = nil) {
        self.id = id
        self.url = url
        self.name = (url as NSString).lastPathComponent
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id ?? ""
    }

    /// Rolled-up status for the session dot: needs ▸ working ▸ idle.
    var status: ClaudeState {
        let states = tabs.compactMap { tabStatus[$0.id] }
        if states.contains(.needs) { return .needs }
        if states.contains(.working) { return .working }
        return .idle
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

    /// `path` is repo-relative here (the diff needs it relative for `git show HEAD:<path>`).
    func openDiff(_ path: String) {
        if let existing = tabs.first(where: { $0.kind == .diff && $0.path == path }) {
            activate(existing.id); return
        }
        addTab(Tab(kind: .diff, title: (path as NSString).lastPathComponent, path: path))
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
