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
    var compaction = false              // notice: the conversation was compacted here — Claude no longer holds
                                        // the messages above, so /rewind can't go back past it
    var version = 0

    // Tool calls
    var toolName = ""
    var toolUseID: String?
    var toolInput: [String: Any] = [:]
    var toolResult: String?
    var toolStatus: ToolStatus = .running
    var subagentSteps = 0               // Agent/Task: tool calls the subagent made
    var subagentLast: String?           // Agent/Task: its latest action ("Bash(echo sub)")

    /// User: thumbnails of the images this message carried, in marker order. Small (built once, ~220pt),
    /// so the transcript shows the picture instead of a bare `[Image #n]`.
    var images: [NSImage] = []

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
struct ChatAttachment {
    let number: Int
    let data: Data
    let mediaType: String
    var marker: String { "[Image #\(number)]" }

    /// The biggest `n` in the `[Image #n]` markers a text carries (0 when it carries none).
    static func highestMarker(in text: String) -> Int {
        guard text.contains(markerPrefix), let re = try? NSRegularExpression(pattern: "\\[Image #(\\d+)\\]") else { return 0 }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
            .max() ?? 0
    }

    /// The text with every `[Image #n]` that none of `kept` claims removed, along with the space after it.
    /// `kept` empty strips them all — what the transcript does before drawing the pictures themselves.
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

    private static let markerPrefix = "[Image #"
}

struct ChatCommand { let name: String; let description: String; let hint: String }
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
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)") + suffix
    }

    /// Context window for a model id when Claude hasn't told us yet (it does, in each turn's `result`).
    static func contextWindow(_ id: String) -> Int { id.contains("[1m]") ? 1_000_000 : 200_000 }
}
