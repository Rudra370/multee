import Foundation

/// Folder trust for chat tabs. Claude's terminal UI asks "Do you trust the files in this folder?" before it
/// loads a folder's own settings (hooks, pre-approved tools); print mode (`-p`, what a chat tab runs) skips
/// that prompt. So a chat tab asks first — unless Claude already recorded trust for the folder in
/// `~/.claude.json`, or the user trusted it here before (kept in our defaults, never written to Claude's
/// own config, which live Claude processes also write).
enum ChatTrust {
    private static let key = "chat.trustedFolders"

    static func isTrusted(_ cwd: String) -> Bool {
        let paths = variants(cwd)
        let ours = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if paths.contains(where: ours.contains) { return true }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return false }
        return paths.contains { (projects[$0] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true }
    }

    static func remember(_ cwd: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        for p in variants(cwd) where !list.contains(p) { list.append(p) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// The folder itself — exact match, like Claude (trust on `/` or a parent doesn't carry down: verified,
    /// Claude still prompts for a subfolder). Both spellings of a symlinked path: `/tmp/x` is `/private/tmp/x`
    /// to Claude, and `resolvingSymlinksInPath` *strips* `/private`, so resolve with realpath(3).
    private static func variants(_ cwd: String) -> [String] {
        var out = [(cwd as NSString).standardizingPath]
        if let r = realpath(cwd, nil) { out.append(String(cString: r)); free(r) }
        return Array(Set(out))
    }

    /// What trusting would enable: the folder's own Claude settings files that carry hooks or allow rules.
    static func folderSettingsNote(_ cwd: String) -> String? {
        var found: [String] = []
        for name in [".claude/settings.json", ".claude/settings.local.json"] {
            let path = (cwd as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var what: [String] = []
            if obj["hooks"] != nil { what.append("hooks") }
            if let allow = (obj["permissions"] as? [String: Any])?["allow"] as? [Any], !allow.isEmpty {
                what.append("\(allow.count) pre-approved tool rule\(allow.count == 1 ? "" : "s")")
            }
            if !what.isEmpty { found.append("\(name) (\(what.joined(separator: ", ")))") }
        }
        return found.isEmpty ? nil : found.joined(separator: "; ")
    }
}
