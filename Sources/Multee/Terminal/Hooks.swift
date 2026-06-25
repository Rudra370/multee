import Foundation

// Hooks injected when launching `claude`. Each event runs a helper script that reads Claude's JSON
// payload from stdin, extracts Claude's own `session_id` (for `--resume`), and pings our listener
// with the tab id, the status, and that conversation id (`cid`).
enum Hooks {
    /// Path to the helper script, written once to a temp file (chmod +x). No jq/python dependency.
    static let scriptPath: String = {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("multee-hook.sh")
        let script = """
        #!/bin/sh
        input=$(cat)
        cid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        # SessionStart (`session`) only reports the id so a resumed tab is named without needing a prompt.
        # Skip a brand-new "startup" session — its transcript doesn't exist yet, so there's nothing to read
        # and nothing to resume; the id gets captured later on first activity instead.
        if [ "$1" = "session" ]; then
          src=$(printf '%s' "$input" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
          [ "$src" = "startup" ] && exit 0
        fi
        # On a prompt, carry the prompt text (base64url, capped) so a live tab can be named immediately —
        # Claude doesn't write the session transcript to disk until later, so reading it isn't reliable yet.
        extra=""
        if [ "$1" = "prompt" ]; then
          p=$(printf '%s' "$input" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\\(.*\\)"[[:space:]]*}[[:space:]]*$/\\1/p' | cut -c1-120)
          [ -n "$p" ] && extra="&p=$(printf '%s' "$p" | base64 | tr -d '\\n' | tr '+/' '-_')"
        fi
        curl -s "http://127.0.0.1:$MULTEE_HOOK_PORT/?s=$MULTEE_SESSION_ID&e=$1&cid=$cid$extra" >/dev/null 2>&1
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }()

    /// Settings JSON wiring every event to the helper script. Built once.
    static let json: String = {
        let s = scriptPath
        func cmd(_ state: String) -> [String: Any] {
            ["hooks": [["type": "command", "command": "sh \"\(s)\" \(state)"]]]
        }
        func cmd(_ state: String, matcher: String) -> [String: Any] {
            ["matcher": matcher, "hooks": [["type": "command", "command": "sh \"\(s)\" \(state)"]]]
        }
        // SessionStart captures the conversation id **without** touching the status dot (the `session`
        // event is status-neutral in `HookServer`), so a tab resumed at launch is named right away. The
        // script drops the "startup" source (a fresh session has no saved transcript yet); a fresh tab is
        // still captured later on its first activity. A fork's SessionStart reports the *parent's* id — the
        // status router ignores that (it equals the tab's `forkParentId`) so it never breaks fork-once.
        let hooks: [String: Any] = [
            "SessionStart": [cmd("session")],
            "UserPromptSubmit": [cmd("prompt")],   // status-wise = working; also carries the prompt text (→ tab name)
            "PreToolUse": [cmd("working", matcher: "")],
            "Stop": [cmd("idle")],
            "Notification": [cmd("needs", matcher: "permission_prompt"),
                             cmd("idle", matcher: "idle_prompt")],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }()
}
