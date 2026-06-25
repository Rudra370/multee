import Foundation

/// Reads facts out of Claude Code's own session transcripts (`~/.claude/projects/<encoded cwd>/<id>.jsonl`).
/// Used to label a Claude tab with the session's name. These files grow to tens of MB, so every read here
/// is bounded — we never load a whole transcript.
enum ClaudeTranscript {
    /// Absolute path to a conversation transcript by session id, or nil if none on disk. The id is a UUID,
    /// so the project-dir name (an encoding of the cwd) doesn't matter — we look it up under any of them.
    static func file(forSessionId id: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        let name = "\(id).jsonl"
        for dir in dirs {
            let p = projects.appendingPathComponent(dir).appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// The best display name for a Claude session, or nil if none yet (the transcript doesn't exist).
    /// Prefers Claude's own auto-generated **`ai-title`** (what it shows in the `--resume` picker); falls
    /// back to the session's **first user prompt** — `ai-title` isn't generated for short conversations,
    /// so without the fallback brand-new/short sessions would never get a name beyond "Claude".
    static func title(forSessionId id: String) -> String? {
        guard let path = file(forSessionId: id) else { return nil }
        return aiTitle(path: path) ?? firstPrompt(path: path)
    }

    /// Claude's `ai-title` — rewritten periodically, so the newest is always near the end. **Tail 256 KB**
    /// keeps the cost flat no matter how large the file grows; a sliced leading partial line just fails to
    /// parse and is skipped.
    private static func aiTitle(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let tail: UInt64 = 256 * 1024
        guard let size = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        var latest: String?
        for line in text.split(separator: "\n") where line.contains("\"ai-title\"") {
            if let v = jsonString(line, key: "aiTitle") { latest = v }   // keep scanning → last wins
        }
        return latest
    }

    /// The session's first user prompt (Claude writes a compact `last-prompt` record per prompt; the first
    /// one is the first prompt and sits near the start). **Head 256 KB** bounds the read; newlines are
    /// collapsed so it fits a tab title.
    private static func firstPrompt(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 256 * 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"last-prompt\"") {
            if let v = jsonString(line, key: "lastPrompt") {
                return v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parse one JSONL line and return a non-empty trimmed string value for `key`, or nil.
    private static func jsonString(_ line: Substring, key: String) -> String? {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}
