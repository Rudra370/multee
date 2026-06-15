import Foundation

/// Claude run state, surfaced as the per-tab / per-session status dot.
enum ClaudeState: String { case idle, working, needs }

/// What a tab shows.
enum TabKind: String, Codable { case claude, terminal, file, diff, search }

/// A single tab in a session. Value type — sessions hold `[Tab]` and mutate by index, so changes
/// flow through `Session`'s `@Published var tabs` for free.
struct Tab: Identifiable, Equatable {
    var id: String
    var kind: TabKind
    var title: String
    var args: String              // claude launch args (for .claude)
    var path: String?             // absolute file path (for .file / .diff)
    var claudeSessionId: String?  // captured from hooks → used to `claude --resume` after a restart
    var dirty: Bool               // unsaved edits (for .file)
    var shown: Bool               // lazy-spawn gate: process isn't started until first viewed

    init(id: String = UUID().uuidString,
         kind: TabKind,
         title: String,
         args: String = "",
         path: String? = nil,
         claudeSessionId: String? = nil,
         dirty: Bool = false,
         shown: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.args = args
        self.path = path
        self.claudeSessionId = claudeSessionId
        self.dirty = dirty
        self.shown = shown
    }
}
