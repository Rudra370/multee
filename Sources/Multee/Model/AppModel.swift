import Foundation
import Combine

/// Root app state: the open sessions, which is active, and settings. Restores on launch and
/// debounce-saves on any structural change (gated by `settings.restoreOnLaunch`).
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String? = nil
    @Published var showSettings: Bool = false

    let settings = Settings()

    private var cancellables = Set<AnyCancellable>()
    private var sessionObservers: [String: AnyCancellable] = [:]
    private let saveTrigger = PassthroughSubject<Void, Never>()

    init() {
        restore()

        // Debounced persistence: any structural change schedules one save.
        saveTrigger
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)

        // Structural changes at the app level (open/close session, switch).
        $sessions.dropFirst().sink { [weak self] _ in self?.scheduleSave() }.store(in: &cancellables)
        $activeSessionID.dropFirst().sink { [weak self] _ in self?.scheduleSave() }.store(in: &cancellables)
    }

    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }

    // MARK: - Sessions

    @discardableResult
    func openRepo(_ path: String) -> Session {
        let resolved = (path as NSString).standardizingPath
        if let existing = sessions.first(where: { $0.url == resolved }) {
            activeSessionID = existing.id
            return existing
        }
        var tabs: [Tab] = []
        if settings.autoLaunchClaude {
            tabs.append(Tab(kind: .claude, title: "Claude", args: settings.defaultArgs))
        }
        let session = Session(url: resolved, tabs: tabs)
        observe(session)
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    func closeSession(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessionObservers[id] = nil
        sessions.remove(at: idx)
        if activeSessionID == id {
            activeSessionID = sessions.indices.contains(idx) ? sessions[idx].id : sessions.last?.id
        }
    }

    // MARK: - Persistence

    private func observe(_ session: Session) {
        sessionObservers[session.id] = session.objectWillChange
            .sink { [weak self] in self?.scheduleSave() }
    }

    private func scheduleSave() { saveTrigger.send(()) }

    private func save() {
        guard settings.restoreOnLaunch else { return }   // stateless when restore is off
        let state = PersistedState(
            sessions: sessions.map { s in
                PersistedSession(
                    url: s.url,
                    tabs: s.tabs.map {
                        PersistedTab(kind: $0.kind.rawValue, title: $0.title, args: $0.args,
                                     path: $0.path, claudeSessionId: $0.claudeSessionId)
                    },
                    activeTabIndex: s.tabs.firstIndex { $0.id == s.activeTabID }
                )
            },
            activeSessionIndex: sessions.firstIndex { $0.id == activeSessionID }
        )
        Persistence.save(state)
    }

    private func restore() {
        guard settings.restoreOnLaunch, let state = Persistence.load() else { return }
        for ps in state.sessions {
            guard FileManager.default.fileExists(atPath: ps.url) else { continue }   // repo gone → drop
            let tabs = ps.tabs.compactMap { pt -> Tab? in
                guard let kind = TabKind(rawValue: pt.kind) else { return nil }
                return Tab(kind: kind, title: pt.title, args: pt.args,
                           path: pt.path, claudeSessionId: pt.claudeSessionId)
            }
            let activeID = ps.activeTabIndex.flatMap { tabs.indices.contains($0) ? tabs[$0].id : nil }
            let session = Session(url: ps.url, tabs: tabs, activeTabID: activeID)
            observe(session)
            sessions.append(session)
        }
        if let i = state.activeSessionIndex, sessions.indices.contains(i) {
            activeSessionID = sessions[i].id
        } else {
            activeSessionID = sessions.first?.id
        }
    }
}
