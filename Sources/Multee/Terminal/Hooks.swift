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
        curl -s "http://127.0.0.1:$MULTEE_HOOK_PORT/?s=$MULTEE_SESSION_ID&e=$1&cid=$cid" >/dev/null 2>&1
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
        // NB: no SessionStart hook — we only capture the conversation id once there's real activity
        // (a prompt), so an untouched Claude tab restores fresh instead of trying to --resume a
        // conversation Claude never saved.
        let hooks: [String: Any] = [
            "UserPromptSubmit": [cmd("working")],
            "PreToolUse": [cmd("working", matcher: "")],
            "Stop": [cmd("idle")],
            "Notification": [cmd("needs", matcher: "permission_prompt"),
                             cmd("idle", matcher: "idle_prompt")],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }()
}
