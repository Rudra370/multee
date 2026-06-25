import Foundation

/// Claude run state, surfaced as the per-tab / per-session status dot.
/// `done` = finished its turn and waiting for you (an attention state, shown like `needs`) — set when a
/// session completes while you're not looking, cleared when you open that tab.
enum ClaudeState: String { case idle, working, needs, done }

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
    var forkParentId: String?     // transient: a fork's source conversation id → launch `--resume <id> --fork-session`
                                  // once, until this tab captures its own claudeSessionId; not persisted
    var dirty: Bool               // unsaved edits (for .file)
    var shown: Bool               // lazy-spawn gate: process isn't started until first viewed
    var exited: Bool              // transient: the terminal process ended (→ "Session ended" bar); not persisted

    init(id: String = UUID().uuidString,
         kind: TabKind,
         title: String,
         args: String = "",
         path: String? = nil,
         claudeSessionId: String? = nil,
         forkParentId: String? = nil,
         dirty: Bool = false,
         shown: Bool = false,
         exited: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.args = args
        self.path = path
        self.claudeSessionId = claudeSessionId
        self.forkParentId = forkParentId
        self.dirty = dirty
        self.shown = shown
        self.exited = exited
    }
}
