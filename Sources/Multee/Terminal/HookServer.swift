import Foundation
import Network

/// Local HTTP listener that Claude's hooks `curl` to report status + the conversation id. Tab ids
/// are our `String` ids (passed to Claude as `MULTEE_SESSION_ID`), routed back verbatim.
final class HookServer {
    static let shared = HookServer()

    private(set) var port: UInt16 = 0
    var onStatus: ((String, ClaudeState) -> Void)?
    var onClaudeId: ((String, String) -> Void)?   // (tab id, Claude's resume session id)
    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        guard let l = try? NWListener(using: .tcp) else { return }
        l.stateUpdateHandler = { state in
            if case .ready = state, let p = l.port { self.port = p.rawValue }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global())
        listener = l
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, _ in
            if let data, let req = String(data: data, encoding: .utf8) { self?.parse(req) }
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func parse(_ req: String) {
        guard let line = req.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let query = parts[1].split(separator: "?").dropFirst().first else { return }
        var s: String?, e: String?, cid: String?
        for kv in query.split(separator: "&") {
            let pair = kv.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0] == "s" { s = String(pair[1]) }
            if pair[0] == "e" { e = String(pair[1]) }
            if pair[0] == "cid" { cid = String(pair[1]) }
        }
        guard let s, !s.isEmpty, let e else { return }
        let state: ClaudeState = e == "working" ? .working : e == "needs" ? .needs : .idle
        DispatchQueue.main.async {
            self.onStatus?(s, state)
            if let cid, !cid.isEmpty { self.onClaudeId?(s, cid) }
        }
    }
}
