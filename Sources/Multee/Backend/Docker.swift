import Foundation

/// Docker CLI helpers. Phase 1 only needs daemon detection; later phases add compose discovery,
/// `ps`/`config`, the event stream, and actions.
enum Docker {
    /// Absolute path to the `docker` binary on the login PATH (GUI apps get a minimal PATH; `Env`
    /// resolves against the full login-shell PATH captured at startup). Returns "docker" unchanged if
    /// not installed — `Shell.runFull` then fails to launch and `isAvailable()` reports false.
    static var bin: String { Env.resolve("docker") }

    /// Cumulative count of `docker` subprocesses we've spawned (availability probes, `services` refreshes,
    /// event-stream connects). A diagnostic for the "no idle polling" guarantee — it must stay flat while
    /// the panel sits idle and only tick when something actually changes. Approximate (incremented off
    /// several threads); only its *movement* is asserted, never an exact value.
    static var cmdCount = 0

    /// Is the Docker daemon reachable? `docker info` honors the active context / `DOCKER_HOST`, so this
    /// works for Docker Desktop's default socket. It exits non-zero (and prints nothing to stdout) when
    /// the daemon is down or `docker` isn't installed. Run this **off-main** — it spawns a subprocess.
    static func isAvailable() -> Bool {
        cmdCount += 1
        let r = Shell.runFull(bin, ["info", "--format", "{{.ServerVersion}}"])
        return r.code == 0 && !r.out.isEmpty
    }

    // MARK: - Compose file discovery (Phase 2)

    /// Compose files found in a repo's root, classified for the picker.
    struct ComposeFiles: Equatable {
        var base: String?              // first standard name by precedence (filename only)
        var override: String?          // compose.override.* / docker-compose.override.*
        var variants: [String] = []    // env variants (`compose.prod.yaml`), sorted
        var extras: [String] = []      // user-added files (odd names / outside root), full paths, sorted

        /// Canonical merge order: base → override → variants → user-added.
        var ordered: [String] { ([base, override].compactMap { $0 }) + variants + extras }
        var all: [String] { ordered }
        /// Pre-selected when the user hasn't picked anything: base + auto-override.
        var defaultSelection: [String] { [base, override].compactMap { $0 } }
        var isEmpty: Bool { ordered.isEmpty }
    }

    /// Scan a repo's **root** (no subfolders) for compose files. Recognizes the four standard names, the
    /// auto-merge override, and env variants (`compose.prod.yaml` → a variant). Pure file listing — cheap,
    /// no daemon needed.
    static func discoverComposeFiles(repo: String) -> ComposeFiles {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repo)) ?? []
        var result = ComposeFiles()
        var bases: [String] = []
        for name in names {
            let lower = name.lowercased()
            guard lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") else { continue }
            let stem = lower.hasSuffix(".yaml") ? String(lower.dropLast(5)) : String(lower.dropLast(4))
            if stem == "compose" || stem == "docker-compose" {
                bases.append(name)
            } else if stem == "compose.override" || stem == "docker-compose.override" {
                result.override = name
            } else if stem.hasPrefix("compose.") || stem.hasPrefix("docker-compose.") {
                result.variants.append(name)
            }
        }
        // base precedence: compose.yaml > compose.yml > docker-compose.yaml > docker-compose.yml
        let precedence = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        for p in precedence { if let hit = bases.first(where: { $0.lowercased() == p }) { result.base = hit; break } }
        result.variants.sort()
        return result
    }

    // MARK: - Services (Phase 3)

    enum ServiceState: String { case running, starting, stopped, other }

    struct ComposeService: Equatable {
        var name: String
        var state: ServiceState
        var ports: [String]    // e.g. ["18080->80", "5432"]
        var count: Int = 0     // running/known container count (shows "×N" when a service is scaled)
        var hasBuild = false   // has a `build:` context → show Build / Rebuild affordances (else they'd no-op)
    }

    /// The services plus the running compose project name (from container labels, nil when nothing is
    /// running), plus a config error when the compose file(s) won't parse (so the UI can explain an empty
    /// list instead of just showing "No services").
    struct ServicesResult { var services: [ComposeService]; var project: String?; var configError: String? }

    /// Every service defined in the selected compose file(s), each tagged with its live state + published
    /// ports. The full list comes from `config --services` (a parse — services that aren't running still
    /// appear, as `.stopped`); live state/ports come from `ps -a`. Spawns subprocesses → call **off-main**.
    static func services(repo: String, files: [String]) -> ServicesResult {
        cmdCount += 2
        let fflags = files.flatMap { ["-f", $0] }
        // One `config` call gives both the defined services and which of them have a `build:` context (so
        // we only offer Build / Rebuild where it does something). JSON object keys are unordered → sort for
        // stable row order (matches the alphabetical order `config --services` used to give).
        let configRes = Shell.runFull(bin, ["compose"] + fflags + ["config", "--format", "json"], cwd: repo)
        var defined: [String] = []
        var buildable: Set<String> = []
        if configRes.code == 0, let data = configRes.out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let svcMap = obj["services"] as? [String: Any] {
            defined = svcMap.keys.sorted()
            for (name, v) in svcMap where (v as? [String: Any])?["build"] != nil { buildable.insert(name) }
        }
        if defined.isEmpty {   // JSON parse failed / odd compose version — fall back to the plain name list
            cmdCount += 1
            let names = Shell.runFull(bin, ["compose"] + fflags + ["config", "--services"], cwd: repo).out
            defined = names.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.sorted()
        }

        let psOut = Shell.runFull(bin, ["compose"] + fflags + ["ps", "-a", "--format", "json"], cwd: repo).out
        let (entries, project) = parsePs(psOut)
        var grouped: [String: [PsEntry]] = [:]
        for e in entries { grouped[e.service, default: []].append(e) }   // a service may have several containers (replicas)

        // Services come ONLY from the compose config — never from `ps`. (Falling back to ps surfaced
        // leftover/orphan containers from a previous compose version as phantom services.)

        let svcs = defined.map { name -> ComposeService in
            let g = grouped[name] ?? []
            var ports: [String] = []
            for e in g { for p in e.ports where !ports.contains(p) { ports.append(p) } }
            return ComposeService(name: name, state: aggregateState(g.map { $0.state }), ports: ports,
                                  count: g.count, hasBuild: buildable.contains(name))
        }
        let configError = (configRes.code != 0) ? (configRes.err.isEmpty ? configRes.out : configRes.err) : nil
        return ServicesResult(services: svcs, project: project, configError: configError)
    }

    /// A service's overall state across its containers: up if any is running, else the "most active" state.
    private static func aggregateState(_ states: [ServiceState]) -> ServiceState {
        if states.contains(.running) { return .running }
        if states.contains(.starting) { return .starting }
        if states.contains(.other) { return .other }
        return .stopped
    }

    /// The compose project name from the merged config (works regardless of running state — needed to
    /// scope volumes when the stack is down). Falls back to nil; the caller can use the default basename.
    static func composeProject(repo: String, files: [String]) -> String? {
        cmdCount += 1
        let fflags = files.flatMap { ["-f", $0] }
        let out = Shell.runFull(bin, ["compose"] + fflags + ["config", "--format", "json"], cwd: repo).out
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["name"] as? String
    }

    // MARK: - Volumes (Phase 7)

    struct ComposeVolume: Equatable {
        var name: String        // full docker name (e.g. docker-p3_apidata) — for size/remove ops
        var display: String     // compose volume name (e.g. apidata) — for the UI
        var driver: String
        var inUse: Bool
        var users: [String]     // service(s) that mount it
        var size: String?       // computed on-demand (expensive)
    }

    /// Volumes belonging to a compose project (label-scoped, host-wide — volumes persist across `down`).
    /// `inUse` comes from the `dangling=true` filter (a dangling volume is referenced by no container, so
    /// it's the only kind safe to remove); `users` maps each volume to the service(s) that mount it.
    /// Spawns subprocesses → call **off-main**.
    static func volumes(project: String) -> [ComposeVolume] {
        cmdCount += 3
        let label = "label=com.docker.compose.project=\(project)"
        let all = volumeList(filters: [label])
        let unused = Set(volumeList(filters: [label, "dangling=true"]).map { $0.name })
        let users = volumeUsers(project: project)
        return all.map { ComposeVolume(name: $0.name, display: $0.display, driver: $0.driver,
                                       inUse: !unused.contains($0.name), users: users[$0.name] ?? [], size: nil) }
    }

    /// Map each project volume (full name) → the compose service(s) that mount it. One `docker ps` with
    /// `--no-trunc` (the truncated `Mounts` column otherwise cuts off volume names).
    private static func volumeUsers(project: String) -> [String: [String]] {
        let out = Shell.runFull(bin, ["ps", "-a", "--no-trunc",
                                      "--filter", "label=com.docker.compose.project=\(project)", "--format", "json"]).out
        var map: [String: Set<String>] = [:]
        for obj in parseJSONLines(out) {
            guard let svc = labelValue(obj["Labels"] as? String ?? "", "com.docker.compose.service") else { continue }
            for m in (obj["Mounts"] as? String ?? "").split(separator: ",") {
                let name = String(m)
                guard !name.hasPrefix("/") else { continue }   // skip bind mounts / host paths — only named volumes
                map[name, default: []].insert(svc)
            }
        }
        return map.mapValues { $0.sorted() }
    }

    private static func volumeList(filters: [String]) -> [(name: String, display: String, driver: String)] {
        var args = ["volume", "ls", "--format", "json"]
        for f in filters { args += ["--filter", f] }
        let out = Shell.runFull(bin, args).out
        return parseJSONLines(out).compactMap { obj in
            guard let name = obj["Name"] as? String else { return nil }
            let labels = obj["Labels"] as? String ?? ""
            let short = labelValue(labels, "com.docker.compose.volume") ?? name
            return (name, short, obj["Driver"] as? String ?? "local")
        }
    }

    /// On-demand size for a volume (scans disk — expensive, never in the list refresh). From `system df -v`.
    static func volumeSize(name: String) -> String? {
        cmdCount += 1
        let out = Shell.runFull(bin, ["system", "df", "-v", "--format", "json"]).out
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vols = obj["Volumes"] as? [[String: Any]] else { return nil }
        return vols.first { ($0["Name"] as? String) == name }?["Size"] as? String
    }

    /// Remove a volume (deletes its data). Refuses if the volume is in use (no `--force`). Returns the error.
    @discardableResult
    static func removeVolume(name: String) -> String? {
        cmdCount += 1
        let r = Shell.runFull(bin, ["volume", "rm", name])
        return r.code == 0 ? nil : (r.err.isEmpty ? r.out : r.err)
    }

    /// Parse a comma-joined Docker labels string for one key's value.
    private static func labelValue(_ labels: String, _ key: String) -> String? {
        for kv in labels.split(separator: ",") {
            let parts = kv.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == key { return String(parts[1]) }
        }
        return nil
    }

    /// Parse `--format json` output that's a JSON array on newer Docker, NDJSON on older.
    private static func parseJSONLines(_ out: String) -> [[String: Any]] {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr }
            return []
        }
        var objects: [[String: Any]] = []
        for line in trimmed.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { objects.append(obj) }
        }
        return objects
    }

    private struct PsEntry { let service: String; let state: ServiceState; let ports: [String] }

    /// Parse `docker compose ps --format json` (a JSON **array** on newer Compose, newline-delimited
    /// objects on older — handle both), returning the entries plus the compose project name (from labels).
    private static func parsePs(_ out: String) -> (entries: [PsEntry], project: String?) {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }
        var objects: [[String: Any]] = []
        if trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { objects = arr }
        } else {
            for line in trimmed.split(separator: "\n") {
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { objects.append(obj) }
            }
        }
        var project: String?
        let entries: [PsEntry] = objects.compactMap { obj in
            if project == nil { project = projectFrom(obj) }
            guard let svc = obj["Service"] as? String else { return nil }
            let state = mapState((obj["State"] as? String ?? "").lowercased(),
                                 health: (obj["Health"] as? String ?? "").lowercased())
            return PsEntry(service: svc, state: state, ports: parsePorts(obj))
        }
        return (entries, project)
    }

    /// Pull `com.docker.compose.project` out of a ps entry's comma-joined `Labels` string.
    private static func projectFrom(_ obj: [String: Any]) -> String? {
        guard let labels = obj["Labels"] as? String else { return nil }
        for kv in labels.split(separator: ",") {
            let parts = kv.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "com.docker.compose.project" { return String(parts[1]) }
        }
        return nil
    }

    private static func mapState(_ s: String, health: String) -> ServiceState {
        if s == "running" { return (health == "unhealthy" || health == "starting") ? .starting : .running }
        if s == "restarting" { return .starting }
        if s == "paused" { return .other }
        if s == "exited" || s == "dead" || s == "created" || s.isEmpty { return .stopped }
        return .other
    }

    private static func parsePorts(_ obj: [String: Any]) -> [String] {
        if let pubs = obj["Publishers"] as? [[String: Any]] {
            var out: [String] = []
            for p in pubs {
                let target = (p["TargetPort"] as? Int) ?? Int(p["TargetPort"] as? String ?? "") ?? 0
                let published = (p["PublishedPort"] as? Int) ?? Int(p["PublishedPort"] as? String ?? "") ?? 0
                guard target != 0 else { continue }
                let s = published != 0 ? "\(published)->\(target)" : "\(target)"
                if !out.contains(s) { out.append(s) }   // de-dup tcp/udp pairs
            }
            return out
        }
        if let portStr = obj["Ports"] as? String, !portStr.isEmpty { return [portStr] }
        return []
    }
}

/// Streams `docker events` (NDJSON) for live container-state changes — the push source that flips the
/// service dots without polling. One instance, started while the Docker panel is open and stopped when it
/// closes, so a closed panel does **zero** work. A socket-stream drop (daemon restart) is observable, so
/// instead of an idle safety-timer it auto-reconnects and asks for a re-snapshot via `onStreamDown`.
final class DockerEvents {
    private(set) var isUp = false
    private var process: Process?
    private var buffer = Data()
    private var stopped = true

    /// (action, project) for each meaningful container event — delivered on the **main** thread.
    var onEvent: ((_ action: String, _ project: String?) -> Void)?
    /// Stream dropped — delivered on the **main** thread, just before the auto-reconnect (used to re-snapshot).
    var onStreamDown: (() -> Void)?

    /// Actions that change what we display (state dot / ports). Excludes the high-frequency `exec_*`,
    /// `attach`, `top`, etc. that healthchecks and shells fire — those would cause needless refreshes.
    private static let meaningful: Set<String> = ["create", "start", "stop", "kill", "die", "pause",
        "unpause", "restart", "destroy", "rename", "update", "health_status", "oom"]

    func start() { guard stopped else { return }; stopped = false; spawn() }

    func stop() {
        stopped = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isUp = false
    }

    private func spawn() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Docker.bin)
        p.arguments = ["events", "--filter", "type=container", "--format", "{{json .}}"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.isUp = false
                self.onStreamDown?()                              // re-snapshot to recover missed events
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.spawn()
                }
            }
        }
        do { try p.run() } catch { isUp = false; return }
        process = p
        isUp = true
        Docker.cmdCount += 1
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // "health_status: healthy" → "health_status"; legacy events use `status` instead of `Action`.
            let raw = (obj["Action"] as? String) ?? (obj["status"] as? String) ?? ""
            let action = raw.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard Self.meaningful.contains(action) else { continue }
            var project: String?
            if let actor = obj["Actor"] as? [String: Any], let attrs = actor["Attributes"] as? [String: Any] {
                project = attrs["com.docker.compose.project"] as? String
            }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(action, project) }
        }
    }
}
