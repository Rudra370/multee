import AppKit
import ImageIO

/// One row of a chat transcript. A value type the session mutates by index on the main thread; `version`
/// bumps on every change so the view's render cache knows what to redo. Ids are monotonic in array order:
/// live items count up from 1, history loaded *above* them counts down from 0 — so the array stays sorted
/// by id and an id's index is a binary search.
struct ChatItem {
    enum Kind { case user, assistant, thinking, tool, notice, error }
    enum ToolStatus { case running, waiting, done, failed, denied, interrupted }

    let id: Int
    var kind: Kind
    var text = ""                       // user text · assistant markdown · thinking · notice/error text
    var uuid: String?                   // user: the message's id in Claude's transcript (what /rewind targets);
                                        // a `!` shell row: its output message's id
    var compaction = false              // notice: the conversation was compacted here — once Claude restarts it
                                        // no longer holds the messages above, so /rewind can't go back past it
    var synthetic = false               // assistant: a built-in command's output (`/cost`), not the model's reply
    var version = 0

    // Tool calls
    var toolName = ""
    var toolUseID: String?
    var toolInput: [String: Any] = [:]
    var toolResult: String?
    var toolStatus: ToolStatus = .running
    var subagentSteps = 0               // Agent/Task: tool calls the subagent made
    var subagentLast: String?           // Agent/Task: its latest action ("Bash(echo sub)")

    /// User: the images this message carried, in marker order — a small thumbnail (built once, ~220pt) so the
    /// transcript shows the picture instead of a bare `[Image #n]`, and the full image's file for Quick Look.
    var images: [ChatPicture] = []

    var streaming = false               // still receiving deltas
    var expanded = false                // long tool output / thinking shown in full

    init(id: Int, kind: Kind, text: String = "") {
        self.id = id; self.kind = kind; self.text = text
    }

    /// A command you ran with `!` (shell mode) is a tool row under this name: input `command`, result the
    /// output. Not one of Claude's tools.
    static let shellTool = "!"
    var isShell: Bool { kind == .tool && toolName == Self.shellTool }
    /// Shell output ending in `ChatShell`'s failure note ("[exit code 1]", "[stopped]") — how history knows
    /// a command failed (the transcript keeps no exit status).
    static func shellOutputFailed(_ s: String) -> Bool {
        guard let last = s.split(separator: "\n").last else { return false }
        return last.hasPrefix("[exit code ") || last.hasPrefix("[stopped")
    }
}

/// A tool-permission prompt, question, or plan approval Claude is waiting on (`can_use_tool`).
struct ChatPrompt {
    enum Kind { case permission, question, plan }
    let requestID: String
    let toolName: String
    let input: [String: Any]
    let toolUseID: String?
    let suggestions: [[String: Any]]    // "always allow" rule / mode changes Claude proposes
    let reason: String?
    var kind: Kind {
        switch toolName {
        case "AskUserQuestion": return .question
        case "ExitPlanMode": return .plan
        default: return .permission
        }
    }
}

/// A background task Claude started (a `run_in_background` shell, an async subagent).
struct ChatTask {
    let id: String
    var type: String                    // local_bash · local_agent · …
    var description: String
    var status = "running"              // running · completed · failed · killed · stopped
    var startedAt = Date()
    var endedAt: Date?
    var outputFile: String?
    var toolUseID: String?
    var activity: String?               // subagent: "Running Echo the word…"
    var ports: [Int] = []               // listening TCP ports found under this task's process
    var isRunning: Bool { status == "running" }
    var isShell: Bool { type == "local_bash" }
}

/// An image pasted (or dropped) into the message box: `[Image #n]` in the text, an image block on the wire.
/// A picture in a sent message: the thumbnail the transcript draws, and where the full image is on disk
/// (`ChatImageCache`) — only the path stays in memory. nil when it couldn't be written.
struct ChatPicture {
    let thumbnail: NSImage
    let file: URL?
}

struct ChatAttachment {
    let number: Int
    let data: Data
    let mediaType: String
    var marker: String { "[Image #\(number)]" }

    /// The text with every `[Image #n]` that none of `kept` claims removed, along with the space after it.
    /// `kept` empty strips them all — what the transcript does before drawing the pictures themselves (messages
    /// sent before the thumbnail strip carried markers in their text).
    static func stripMarkers(_ text: String, keeping kept: [ChatAttachment]) -> String {
        guard text.contains(markerPrefix), let re = try? NSRegularExpression(pattern: "\\[Image #\\d+\\] ?") else { return text }
        let keep = Set(kept.map(\.marker))
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hit = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            if keep.contains(hit.hasSuffix(" ") ? String(hit.dropLast()) : hit) { out += hit }
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    /// A small picture of encoded image bytes, for showing a sent image in the transcript. ImageIO decodes
    /// straight to the size we want (never the full bitmap) and is safe off the main thread, which is where
    /// history is parsed. `side` is in points; the pixels are 2× for a retina screen.
    static func thumbnail(_ data: Data, side: CGFloat = 200) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side * 2,
              ] as CFDictionary) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, side / max(w, h))
        return NSImage(cgImage: cg, size: NSSize(width: (w * scale).rounded(), height: (h * scale).rounded()))
    }

    /// This attachment as that small picture.
    var thumbnail: NSImage? { Self.thumbnail(data) }

    /// Thumbnail + full image on disk, for a message that carries it.
    var picture: ChatPicture? { thumbnail.map { ChatPicture(thumbnail: $0, file: ChatImageCache.store(data, mediaType: mediaType)) } }

    private static let markerPrefix = "[Image #"
}

struct ChatCommand {
    let name: String; let description: String; let hint: String
    /// A skill or custom command — something Claude can also pick up mid-message (with its Skill tool). The rest
    /// (Claude's built-ins, Multee's own) only mean something at the start of a message.
    var skill = false
}
struct ChatModelOption {
    let value: String; let displayName: String; let description: String; let resolved: String
    var effortLevels: [String] = []     // empty = effort not supported (Haiku)
    var supportsFastMode = false
    var supportsAutoMode = false
}
struct RateWindow { let utilization: Double; let resetsAt: Date }

/// Anything that renders a chat session. Index-level callbacks let the transcript view touch only the rows
/// that changed — a streaming reply re-renders one row, not the list.
protocol ChatSessionObserver: AnyObject {
    func chatItemsReset()
    func chatItemsAppended(_ range: Range<Int>)
    func chatItemsPrepended(_ count: Int)
    func chatItemsTruncated()           // items were removed from the end (a rewind)
    func chatItemChanged(at index: Int)
    func chatStateChanged()
}

/// Human name for a model id: `claude-opus-5[1m]` → "Opus 5 (1M context)", `claude-haiku-4-5-20251001` →
/// "Haiku 4.5". Unknown shapes pass through unchanged.
enum ModelName {
    static func display(_ id: String) -> String {
        var s = id
        var suffix = ""
        if let r = s.range(of: "[1m]") { s.removeSubrange(r); suffix = " (1M context)" }
        guard s.hasPrefix("claude-") else { return id }
        var parts = s.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }   // date stamp
        guard let family = parts.first, !family.isEmpty else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + String(family.dropFirst())
        return name + (version.isEmpty ? "" : " \(version)") + suffix
    }

    /// Context window for a model id when Claude hasn't told us yet (it does, in each turn's `result`).
    static func contextWindow(_ id: String) -> Int { id.contains("[1m]") ? 1_000_000 : 200_000 }
}

/// How long compactions take here, to say "usually about 15s" while one runs. Claude reports only a
/// compaction's start and end — no progress — so the only honest hint is what past ones of a similar size, on
/// the same model, took. Duration is driven mostly by how long a summary the model writes, so this stays a hint.
enum CompactTiming {
    struct Sample: Codable, Equatable { let model: String; let tokens: Int; let seconds: Double }

    static let key = "multee.chat.compactTimes"
    static let kept = 30

    /// Typical seconds for compacting `tokens` of context on `model`: the median of past compactions within 2×
    /// of that size on the same model — nil until there are two, so a first guess never poses as knowledge.
    static func estimate(tokens: Int, model: String, from samples: [Sample]) -> Int? {
        guard tokens > 0 else { return nil }
        let near = samples.filter { $0.model == model && $0.tokens * 2 >= tokens && $0.tokens <= tokens * 2 }
            .map(\.seconds).sorted()
        guard near.count >= 2 else { return nil }
        let mid = near.count / 2
        let median = near.count % 2 == 1 ? near[mid] : (near[mid - 1] + near[mid]) / 2
        return rounded(median)
    }

    /// Whole seconds under 20, then to the nearest 5 — "about 45s", not "about 43s".
    static func rounded(_ s: Double) -> Int { s < 20 ? max(1, Int(s.rounded())) : Int((s / 5).rounded()) * 5 }

    /// The newest `kept` samples after adding one (oldest dropped first).
    static func adding(_ sample: Sample, to samples: [Sample]) -> [Sample] { Array((samples + [sample]).suffix(kept)) }

    static func load() -> [Sample] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    static func record(_ sample: Sample) {
        guard sample.tokens > 0, sample.seconds > 0 else { return }
        if let data = try? JSONEncoder().encode(adding(sample, to: load())) { UserDefaults.standard.set(data, forKey: key) }
    }
}
