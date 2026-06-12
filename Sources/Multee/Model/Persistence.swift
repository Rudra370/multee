import Foundation

// JSON snapshot persisted to UserDefaults("multee.state"). Tab/session ids are random UUIDs that
// regenerate on restore, so active selections are persisted by *index*, not id.

struct PersistedTab: Codable {
    var kind: String
    var title: String
    var args: String
    var path: String?
    var claudeSessionId: String?
}

struct PersistedSession: Codable {
    var url: String
    var tabs: [PersistedTab]
    var activeTabIndex: Int?
}

struct PersistedState: Codable {
    var sessions: [PersistedSession]
    var activeSessionIndex: Int?
}

enum Persistence {
    static let key = "multee.state"

    static func load() -> PersistedState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
