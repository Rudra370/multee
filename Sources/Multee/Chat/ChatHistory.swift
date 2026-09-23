import AppKit

/// Reads a conversation's past messages from Claude's transcript (`~/.claude/projects/…/<id>.jsonl`) so a
/// resumed chat tab shows its history — `claude -p --resume` continues the conversation but doesn't replay
/// it. Transcripts reach hundreds of MB, so reads are **bounded chunks from the end**: the newest slice
/// loads first and "Load earlier" walks backwards. Runs off the main thread.
///
/// A transcript is a tree, not a list: `/rewind` leaves the undone messages in the file and continues from an
/// earlier one (`parentUuid`). Only the **live branch** is shown — the same one Claude resumes: from the leaf
/// (the last message, or an explicit `last-prompt` marker written after it, e.g. by a rewind) back through
/// each message's parent.
enum ChatHistory {
    /// How a read picks the live branch: find its leaf (the newest chunk), follow it from a message the
    /// later chunk pointed to, or nothing left (the branch reached the conversation's first message).
    enum Branch: Equatable { case find, follow(String), root }

    struct Chunk {
        var items: [ChatItem]           // ids are placeholders; the session re-ids them
        var startOffset: UInt64         // where this chunk began — the next (earlier) read ends here (0 = done)
        var results: [String: (String, Bool)] = [:]   // tool results whose call is in an earlier chunk
        var branch: Branch = .find      // what the next (earlier) read continues with
    }

    static let chunkBytes: UInt64 = 2 * 1024 * 1024

    /// Parse the slice of `path` that ends at `endOffset` (nil = end of file), at most `maxBytes` long.
    static func load(path: String, endOffset: UInt64?, branch: Branch = .find, maxBytes: UInt64 = chunkBytes) -> Chunk? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let end = min(endOffset ?? size, size)
        var start = end > maxBytes ? end - maxBytes : 0
        var data = Data()
        while true {
            try? h.seek(toOffset: start)
            guard let d = try? h.read(upToCount: Int(end - start)) else { return nil }
            data = d
            guard start > 0 else { break }
            // Drop the partial first line. A slice must keep at least one whole line — one longer than the
            // slice (a huge tool result) widens it, or the next read would start where this one did.
            if let nl = data.firstIndex(of: 0x0A), nl + 1 < data.endIndex {
                data.removeSubrange(data.startIndex...nl)
                start += UInt64(nl - d.startIndex + 1)
                break
            }
            start = start > maxBytes ? start - maxBytes : 0
        }
        var objs: [[String: Any]] = []
        for line in data.split(separator: 0x0A) {
            autoreleasepool {
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { objs.append(obj) }
            }
        }
        // The live branch's messages in this slice (nil = no branch info found — show everything).
        var live: Set<String>?
        var next = branch
        switch branch {
        case .root: live = []
        case .follow(let leaf): (live, next) = walk(from: leaf, objs)
        case .find: if let leaf = newestLeaf(objs) { (live, next) = walk(from: leaf, objs) }
        }
        var items: [ChatItem] = []
        var toolIndex: [String: Int] = [:]
        var orphans: [String: (String, Bool)] = [:]
        for obj in objs {
            if let live, let u = obj["uuid"] as? String, !live.contains(u) { continue }
            parse(obj, into: &items, toolIndex: &toolIndex, orphans: &orphans)
        }
        // Reached the first message: nothing earlier in the file belongs to this conversation.
        if next == .root { start = 0 }
        return Chunk(items: items, startOffset: start, results: orphans, branch: next)
    }

    /// The leaf Claude resumes from: the last main-chain message, unless an explicit `last-prompt` marker
    /// (a rewind's) comes after it.
    private static func newestLeaf(_ objs: [[String: Any]]) -> String? {
        var last: String?, explicit: String?
        for o in objs {
            let type = o["type"] as? String
            if type == "last-prompt" {
                if o["explicit"] as? Bool == true, let leaf = o["leafUuid"] as? String { explicit = leaf }
                continue
            }
            guard let u = o["uuid"] as? String, o["isSidechain"] as? Bool != true,
                  type == "user" || type == "assistant" || type == "attachment" || type == "system" else { continue }
            last = u
            explicit = nil
        }
        return explicit ?? last
    }

    /// Messages on the branch ending at `leaf`, following `parentUuid` (or `logicalParentUuid` across a
    /// compaction), and where the branch continues above this slice.
    private static func walk(from leaf: String, _ objs: [[String: Any]]) -> (Set<String>, Branch) {
        var parents: [String: String?] = [:]
        for o in objs {
            guard let u = o["uuid"] as? String else { continue }
            let parent: String? = (o["parentUuid"] as? String) ?? (o["logicalParentUuid"] as? String)
            parents[u] = .some(parent)         // keep root messages (nil parent) in the map
        }
        var live = Set<String>()
        var cur: String? = leaf
        while let c = cur, let parent = parents[c], !live.contains(c) {
            live.insert(c)
            cur = parent
        }
        return (live, cur.map { .follow($0) } ?? .root)
    }

    private static func parse(_ obj: [String: Any], into items: inout [ChatItem],
                              toolIndex: inout [String: Int], orphans: inout [String: (String, Bool)]) {
        guard obj["isSidechain"] as? Bool != true else { return }   // subagent traffic lives in its tool row
        let type = obj["type"] as? String
        if type == "system" {
            if obj["subtype"] as? String == "compact_boundary" {
                var item = ChatItem(id: 0, kind: .notice, text: "Conversation compacted")
                item.compaction = true
                items.append(item)
            }
            return
        }
        guard type == "user" || type == "assistant", let message = obj["message"] as? [String: Any] else { return }
        if obj["isMeta"] as? Bool == true { return }
        if obj["isCompactSummary"] as? Bool == true {
            var item = ChatItem(id: 0, kind: .notice, text: "Earlier conversation was summarized")
            item.compaction = true
            items.append(item)
            return
        }
        if obj["isApiErrorMessage"] as? Bool == true {
            let text = textOf(message["content"])
            if !text.isEmpty { items.append(ChatItem(id: 0, kind: .error, text: text)) }
            return
        }

        if type == "assistant" {
            for block in blocks(message["content"]) {
                switch block["type"] as? String {
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, t != "No response requested." { items.append(ChatItem(id: 0, kind: .assistant, text: t)) }
                case "thinking":
                    let t = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { items.append(ChatItem(id: 0, kind: .thinking, text: t)) }
                case "tool_use":
                    var item = ChatItem(id: 0, kind: .tool)
                    item.toolName = block["name"] as? String ?? "Tool"
                    item.toolUseID = block["id"] as? String
                    item.toolInput = block["input"] as? [String: Any] ?? [:]
                    item.toolStatus = .interrupted     // until its result shows up below
                    if let id = item.toolUseID { toolIndex[id] = items.count }
                    items.append(item)
                default: break
                }
            }
            return
        }

        // user: plain prompts, slash-command echoes, tool results
        let uuid = obj["uuid"] as? String
        if let s = message["content"] as? String {
            appendUserText(s, uuid: uuid, into: &items)
            return
        }
        var texts: [String] = []
        var pictures: [NSImage] = []
        var images = 0
        for block in blocks(message["content"]) {
            switch block["type"] as? String {
            case "text":
                let t = block["text"] as? String ?? ""
                // `!` shell messages sent mid-turn arrive merged with whatever else was queued, one block each
                // — keep them apart, so a command keeps its output (and a prompt stays a prompt).
                if t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<bash-") { appendUserText(t, uuid: uuid, into: &items) }
                else { texts.append(t) }
            case "image":
                images += 1
                // Decode it small (never the full bitmap) so a reopened chat shows the picture, not a marker.
                if let src = block["source"] as? [String: Any], let b64 = src["data"] as? String,
                   let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), let thumb = ChatAttachment.thumbnail(data) {
                    pictures.append(thumb)
                }
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                let result = toolResultText(block["content"])
                let isError = block["is_error"] as? Bool ?? false
                if let i = toolIndex[id] {
                    items[i].toolResult = result
                    items[i].toolStatus = isError ? (result.contains("denied") || result.contains("rejected") ? .denied : .failed) : .done
                } else {
                    orphans[id] = (result, isError)
                }
            default: break
            }
        }
        var body = texts.joined(separator: "\n")
        // Images we can't show (sent from the terminal UI, so no "[Image #n]" marker, or bytes we failed to
        // decode) get a placeholder — the ones we did decode are drawn instead, so they must not get both.
        let unshown = images - pictures.count
        if unshown > 0, !body.contains("[Image #") {
            body = Array(repeating: "[image]", count: unshown).joined(separator: " ") + (body.isEmpty ? "" : " " + body)
        }
        if !body.isEmpty { appendUserText(body, uuid: uuid, images: pictures, into: &items) }
    }

    /// A user text turn, minus the transcript's wrapper noise: slash-command echoes become "/cmd args",
    /// command output becomes a notice, reminders/caveats are dropped.
    private static func appendUserText(_ raw: String, uuid: String?, images: [NSImage] = [], into items: inout [ChatItem]) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("<local-command-caveat>") || s.hasPrefix("<system-reminder>") { return }
        if s.hasPrefix("[Request interrupted by user") { items.append(ChatItem(id: 0, kind: .notice, text: "Interrupted")); return }
        // A background task finishing is injected as a user turn (it wakes Claude) — show its one-line summary.
        if s.hasPrefix("<task-notification>") {
            let summary = between(s, "<summary>", "</summary>") ?? "Background task finished"
            items.append(ChatItem(id: 0, kind: .notice, text: summary))
            return
        }
        if s.contains("<command-name>") {
            let name = between(s, "<command-name>", "</command-name>") ?? ""
            let args = between(s, "<command-args>", "</command-args>") ?? ""
            let cmd = (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args)
            var item = ChatItem(id: 0, kind: .user, text: cmd)
            item.uuid = uuid
            items.append(item)
            return
        }
        if let out = between(s, "<local-command-stdout>", "</local-command-stdout>") {
            let clean = stripANSI(out).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { items.append(ChatItem(id: 0, kind: .notice, text: clean)) }
            return
        }
        // `!` shell mode: the command, then its output — one shell row, as the chat shows it live.
        if let cmd = between(s, "<bash-input>", "</bash-input>") {
            var item = ChatItem(id: 0, kind: .tool)
            item.toolName = ChatItem.shellTool
            item.toolInput = ["command": cmd]
            item.toolStatus = .done
            item.uuid = uuid            // a message of the conversation (what a rewind names as "last seen")
            items.append(item)
            return
        }
        if s.hasPrefix("<bash-stdout>") || s.hasPrefix("<bash-stderr>") {
            let out = stripANSI(between(s, "<bash-stdout>", "</bash-stdout>") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stripANSI(between(s, "<bash-stderr>", "</bash-stderr>") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            if let last = items.indices.last, items[last].isShell, items[last].toolResult == nil {
                items[last].toolResult = text.isEmpty ? "(no output)" : text
                if ChatItem.shellOutputFailed(err) { items[last].toolStatus = .failed }
                if let uuid { items[last].uuid = uuid }
            } else if !text.isEmpty {
                items.append(ChatItem(id: 0, kind: .notice, text: text))
            }
            return
        }
        var item = ChatItem(id: 0, kind: .user, text: s)
        item.uuid = uuid
        item.images = images
        items.append(item)
    }

    // MARK: - Helpers (also used by the live stream reducer)

    static func blocks(_ content: Any?) -> [[String: Any]] { content as? [[String: Any]] ?? [] }

    /// A message/tool-result `content` as plain text: a string as-is, a block array's text blocks joined.
    static func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return blocks(content).compactMap { b -> String? in
            switch b["type"] as? String {
            case "text": return b["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// A tool result's text, minus the `<tool_use_error>…</tool_use_error>` wrapper Claude puts on failures.
    static func toolResultText(_ content: Any?) -> String {
        let s = textOf(content)
        guard s.contains("<tool_use_error>") else { return s }
        return s.replacingOccurrences(of: "<tool_use_error>", with: "").replacingOccurrences(of: "</tool_use_error>", with: "")
    }

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
