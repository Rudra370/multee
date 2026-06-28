import AppKit
import Combine

/// Lets the bottom-bar Docker icon / the debug harness reach the single Docker panel controller —
/// same static-hook pattern as `QuickTerminalHook` / `QuickAskHook`.
enum DockerHook {
    static var toggle: (() -> Void)?
}

enum ServiceVerb { case start, stop, restart, build, startBuild, pull }
enum ProjectVerb { case up, stop, restart, down, build, pull }

/// Confirmation for destructive-ish actions, with a harness-injectable response (modal `NSAlert`s can't
/// be clicked by the debug harness, so it sets `debugResponse` before triggering the action).
enum DockerConfirm {
    static var debugResponse: Bool?
    static func ask(title: String, info: String, confirmTitle: String, danger: Bool, onConfirm: @escaping () -> Void) {
        if let r = debugResponse { debugResponse = nil; if r { onConfirm() }; return }
        let a = NSAlert()
        a.messageText = title; a.informativeText = info
        a.alertStyle = danger ? .critical : .warning
        a.addButton(withTitle: confirmTitle); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { onConfirm() }
    }
}

/// The Docker panel: a VS Code-style bottom-dock panel (shared with the quick terminal — only one
/// occupies the dock at a time) that lists the active repo's compose services, their state, ports,
/// logs, and volumes.
/// - **Phase 1**: daemon detection (drives the bottom-bar icon) + toggling the dock.
/// - **Phase 2**: compose-file discovery, a persisted per-repo selection, and the picker popover.
final class DockerPanelController: NSObject {
    static weak var current: DockerPanelController?

    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private(set) var isShown = false

    /// Availability is re-checked at startup and on every app-activate (the user typically switches to
    /// Docker Desktop / a terminal to start or quit Docker, so returning focus to Multee is the natural
    /// re-check point). No idle timer — one cheap `docker info` per activation, off-main, never
    /// overlapping (`checking`). This keeps detection dynamic at zero steady-state cost (perf is #1).
    private var checking = false
    /// Debug override (harness `dockerForceAvailable`): nil = real detection, else a forced value so the
    /// "daemon went away mid-session" path is testable without actually stopping Docker.
    private var forcedAvailable: Bool?

    // MARK: Compose selection (Phase 2)
    private var composeRepo: String?
    private var composeFiles = Docker.ComposeFiles()
    private var composeSelected: Set<String> = []
    private let pickerPopover = NSPopover()

    // MARK: Services (Phase 3) — cached so the 1s state-dump / re-render never re-spawn `docker`.
    private var services: [Docker.ComposeService] = []
    private var loadToken = 0   // guards against a stale async load overwriting a newer one

    // MARK: Live updates (Phase 4) — event stream runs only while the panel is open.
    private let events = DockerEvents()
    private var currentProject: String?        // captured from `ps`; lets us filter events to this project
    private var refreshScheduled = false       // debounce: coalesce event bursts into one refresh
    private var lastEventAt: Date?

    // MARK: Action overlay (Phase 5b) — slow actions run in a watchable PTY; peek / open-as-tab / auto-show-on-fail.
    private weak var root: NSView?
    private let overlay = DockerActionOverlay()
    private var actionPTYId: String?
    private var actionRepo: String?    // repo an in-flight action belongs to (guards stale cross-repo UI)
    private var actionLabel = ""

    private let panel = DockerPanel()

    init(model: AppModel) {
        self.model = model
        super.init()
        DockerPanelController.current = self
        panel.onComposeClick = { [weak self] in self?.showPicker() }
        panel.onRefresh = { [weak self] in self?.loadServices() }
        panel.onServiceAction = { [weak self] svc, verb in self?.runServiceAction(svc, verb) }
        panel.onProjectAction = { [weak self] verb in self?.runProjectAction(verb) }
        panel.onServiceLogs = { [weak self] svc in self?.openLogs(service: svc) }
        panel.onServiceExec = { [weak self] svc in self?.openExec(service: svc) }
        panel.onOpenPort = { [weak self] host in self?.openPort(host) }
        panel.onAllLogs = { [weak self] in self?.openLogs(service: nil) }
        panel.onModeChange = { [weak self] idx in if idx == 1 { self?.loadVolumes() } }
        panel.onVolSize = { [weak self] name in self?.loadVolumeSize(name) }
        panel.onVolRemove = { [weak self] name in self?.removeVolume(name) }
        panel.onPeek = { [weak self] in self?.showOverlay() }
        overlay.onClose = { [weak self] in self?.hideOverlay() }
        overlay.onOpenAsTab = { [weak self] in self?.openActionAsTab() }
        TerminalStore.shared.onCommandExit = { [weak self] id, code in self?.handleActionExit(id, code) }
        events.onEvent = { [weak self] action, project in self?.handleEvent(action: action, project: project) }
        events.onStreamDown = { [weak self] in self?.loadServices() }   // reconnect → re-snapshot
        // Re-target when the active session changes while the dock is open (otherwise it shows the
        // previous repo's services/volumes and mis-scopes events to the old project).
        model.$activeSessionID
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.activeSessionChanged() }
            .store(in: &cancellables)
        checkAvailability()   // initial probe
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    private func activeSessionChanged() {
        guard isShown else { return }
        guard model.activeSession != nil else { hide(); return }   // last session closed → dismiss
        pickerPopover.performClose(nil)
        clearActionContext()        // the in-flight/last action belonged to the previous repo
        actingService = nil         // and so did its per-row spinner
        refreshCompose()            // loads the new repo's files (and resets currentProject on repo change)
        panel.setComposeLabel(selectionLabel())
        updateActionsEnabled()
        refreshVisible()            // reload whichever tab is showing, for the new repo
    }

    /// Reload whatever tab is visible (services vs volumes) — used on open, app-activate, and session switch.
    private func refreshVisible() { panel.visibleMode == 1 ? loadVolumes() : loadServices() }

    /// Enable the project-wide action buttons only when a compose file is actually selected (otherwise
    /// `docker compose up` would run with no `-f`).
    private func updateActionsEnabled() { panel.setProjectActionsEnabled(!composeSelected.isEmpty) }

    /// Drop the action overlay/peek for the current action. If an action is still in flight we keep
    /// tracking it (so its exit still stops the spinner) and only hide the overlay.
    private func clearActionContext() {
        guard activeActions == 0 else { hideOverlay(); return }
        if let id = actionPTYId { TerminalStore.shared.close(id) }
        actionPTYId = nil
        actionRepo = nil
        overlay.releaseMounted()
        hideOverlay()
        panel.setPeekVisible(false)
    }

    /// Install the action overlay into the window root (hidden until a peek / a failure).
    func attach(root: NSView) { self.root = root; overlay.install(in: root) }

    /// Stop the event stream on a clean quit so we never orphan a `docker events` subprocess. (A force-kill
    /// can't run this, but an orphaned stream self-terminates on its next write once our pipe closes.)
    @objc private func appWillTerminate() { events.stop(); if let id = actionPTYId { TerminalStore.shared.close(id) } }

    @objc private func appActivated() {
        checkAvailability()
        if isShown { refreshVisible() }   // catch any change (services or volumes) that happened while away
    }

    /// A meaningful container event arrived. A compose container always carries a project label, so a
    /// nil-project event (a plain `docker run`) is never ours. Once we know our project, ignore other
    /// projects too; while we don't (our stack is down), accept any labeled event so a cold `up` is caught.
    /// Then debounce so a burst (e.g. `up` starting several containers) is one `ps`, not many.
    private func handleEvent(action: String, project: String?) {
        guard isShown else { return }
        if let cur = currentProject {
            guard project == cur else { return }
        } else {
            guard project != nil else { return }
        }
        lastEventAt = Date()
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshScheduled = false
            self?.loadServices()
        }
    }

    // MARK: - Daemon availability (drives the bottom-bar icon)

    private func checkAvailability() {
        if let forced = forcedAvailable { setAvailable(forced); return }
        guard !checking else { return }
        checking = true
        DispatchQueue.global().async { [weak self] in
            let ok = Docker.isAvailable()
            DispatchQueue.main.async {
                self?.checking = false
                self?.setAvailable(ok)
            }
        }
    }

    private func setAvailable(_ ok: Bool) {
        guard model.dockerAvailable != ok else { return }
        model.dockerAvailable = ok                    // StatusBarView observes this → shows/hides the icon
        if !ok, isShown { hide() }                    // daemon went away → close an open panel
    }

    // MARK: - Compose file discovery / selection / persistence

    private static func selKey(_ repo: String) -> String { "docker.compose.selection::\(repo)" }

    /// Re-discover compose files for the active repo and load/refresh the selection. Cheap (a dir
    /// listing), so it's safe on panel-show, picker-open, and `dumpDocker`. On a repo switch it loads the
    /// persisted picks (falling back to base+override); within the same repo it keeps the in-memory picks
    /// and just drops any file that vanished from disk.
    private func refreshCompose() {
        guard let repo = model.activeSession?.url else {
            composeRepo = nil; composeFiles = .init(); composeSelected = []; return
        }
        var files = Docker.discoverComposeFiles(repo: repo)
        let discovered = Set(files.all)
        if composeRepo != repo {
            composeRepo = repo
            currentProject = nil   // new repo — don't inherit the previous project's name (events/volumes scope)
            let saved = (UserDefaults.standard.array(forKey: Self.selKey(repo)) as? [String]) ?? []
            // keep a saved entry if it's a discovered file or a user-added file still on disk
            let valid = saved.filter { discovered.contains($0) || FileManager.default.fileExists(atPath: $0) }
            composeSelected = Set(valid.isEmpty ? files.defaultSelection : valid)
        }
        // Reconstruct user-added files: selected entries that aren't discovered but still exist on disk.
        files.extras = composeSelected.subtracting(discovered)
            .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        composeSelected = composeSelected.filter { files.all.contains($0) }   // drop entries that vanished
        composeFiles = files
    }

    /// Whether `path` is inside the project (the repo dir or a subfolder of it).
    private func isInsideRepo(_ path: String) -> Bool {
        guard let repo = composeRepo else { return false }
        let r = URL(fileURLWithPath: repo).standardizedFileURL.path
        let f = URL(fileURLWithPath: path).standardizedFileURL.path
        return f == r || f.hasPrefix(r + "/")
    }

    /// Add a user-picked compose file (odd-named / in a subfolder) by absolute path, selecting it.
    /// Scoped to the project — files outside the repo are rejected.
    func addComposeFile(path: String) {
        guard composeRepo != nil, FileManager.default.fileExists(atPath: path), isInsideRepo(path) else { return }
        composeSelected.insert(path)
        refreshCompose()   // pulls `path` into `extras`
        if let repo = composeRepo {
            UserDefaults.standard.set(composeFiles.ordered.filter { composeSelected.contains($0) }, forKey: Self.selKey(repo))
        }
        panel.setComposeLabel(selectionLabel())
        updateActionsEnabled()
        loadServices()
    }

    /// The selected files in canonical merge order, as `-f a -f b` (empty when nothing is selected).
    private var composeCmd: String {
        composeFiles.ordered.filter { composeSelected.contains($0) }.map { "-f \($0)" }.joined(separator: " ")
    }

    private func selectionLabel() -> String {
        if composeFiles.isEmpty { return "No compose file" }
        let sel = composeFiles.ordered.filter { composeSelected.contains($0) }
        if sel.isEmpty { return "Select compose file" }
        return sel.count == 1 ? sel[0] : "\(sel[0]) +\(sel.count - 1)"
    }

    /// Toggle a file in the selection and persist (the checkbox in the popover and the harness
    /// `dockerPick` both route here). Order is always recomputed canonically, so toggle order never
    /// affects the merge order.
    func togglePick(_ file: String) {
        refreshCompose()
        guard composeFiles.all.contains(file) else { return }
        if composeSelected.contains(file) { composeSelected.remove(file) } else { composeSelected.insert(file) }
        if let repo = composeRepo {
            let ordered = composeFiles.ordered.filter { composeSelected.contains($0) }
            UserDefaults.standard.set(ordered, forKey: Self.selKey(repo))
        }
        panel.setComposeLabel(selectionLabel())
        updateActionsEnabled()
        loadServices()   // the service set comes from the selected files → reload when it changes
    }

    /// Load the service list (defined ∪ live) off-main and render it. `loadToken` drops a stale result if
    /// a newer load started meanwhile (e.g. fast file toggles). Live event-driven refresh is Phase 4; for
    /// now this runs on panel-show, file-toggle, and the manual refresh button.
    private func loadServices() {
        guard let repo = composeRepo else { services = []; currentProject = nil; panel.renderServices([], acting: nil); return }
        let files = composeFiles.ordered.filter { composeSelected.contains($0) }
        // No file selected → don't run `docker compose` with no `-f` (it would pick up a default file and
        // disagree with the picker). Show a clear empty state instead.
        guard !files.isEmpty else {
            services = []; currentProject = nil
            panel.setServicesEmptyText(composeFiles.isEmpty ? "No compose file in this folder" : "Select a compose file")
            panel.renderServices([], acting: nil)
            return
        }
        loadToken += 1
        let token = loadToken
        panel.setLoading(true)
        DispatchQueue.global().async { [weak self] in
            let result = Docker.services(repo: repo, files: files)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.services = result.services
                if let p = result.project { self.currentProject = p }   // keep last known when ps is empty
                if result.services.isEmpty, let err = result.configError {
                    let firstLine = err.split(separator: "\n").first.map(String.init) ?? err
                    self.panel.setServicesEmptyText("⚠ " + String(firstLine.prefix(120)))
                } else {
                    self.panel.setServicesEmptyText("No services")
                }
                self.panel.setLoading(false)
                self.panel.setProjectBuildVisible(result.services.contains { $0.hasBuild })
                self.panel.setProjectPullVisible(result.services.contains { !$0.hasBuild })
                self.panel.renderServices(result.services, acting: self.actingService)
            }
        }
    }

    // MARK: - Actions (Phase 5a) — run the verb, let the event stream flip the dots, surface failures.

    private var activeActions = 0   // header spinner shows while any action is in flight
    private var actingService: String?   // the service whose action is in flight → its row shows a spinner

    /// Per-service Start / Stop / Restart / Build / Pull. `Start = up -d <svc>` (creates if never run, resumes
    /// if stopped). Marks the row as acting (spinner) until the action's PTY exits.
    func runServiceAction(_ service: String, _ verb: ServiceVerb) {
        actingService = service
        panel.renderServices(services, acting: actingService)   // immediate per-row spinner
        switch verb {
        case .start:      runAction(["up", "-d", service])
        case .stop:       runAction(["stop", service])
        case .restart:    runAction(["restart", service])
        case .build:      runAction(["build", service])
        case .startBuild: runAction(["up", "-d", "--build", service])
        case .pull:       runAction(["pull", service])
        }
    }

    /// Project-wide actions. `down` removes containers (recoverable) → a light confirm first.
    func runProjectAction(_ verb: ProjectVerb) {
        switch verb {
        case .up:      runAction(["up", "-d"])
        case .stop:    runAction(["stop"])
        case .restart: runAction(["restart"])
        case .build:   runAction(["build"])
        case .pull:    runAction(["pull"])
        case .down:
            DockerConfirm.ask(title: "Tear down this stack?",
                              info: "Stops and removes the project's containers and networks. Your data in volumes is kept, so you can bring it back up.",
                              confirmTitle: "Down", danger: false) { [weak self] in self?.runAction(["down"]) }
        }
    }

    /// Run a compose action in a **PTY** so it's watchable (live build/pull output). A spinner + peek icon
    /// show while it runs; the dots flip via the event stream; on a non-zero exit the overlay auto-shows.
    /// One action PTY at a time — a new action replaces the previous one.
    private func runAction(_ verb: [String]) {
        guard let repo = composeRepo else { actingService = nil; return }   // bailed → don't strand the spinner
        let files = composeFiles.ordered.filter { composeSelected.contains($0) }
        let fflags = files.flatMap { ["-f", $0] }
        if let prev = actionPTYId {
            // Replacing an in-flight action: close() removes the view, so its `processTerminated` reverse
            // lookup fails and `handleActionExit` never runs for it — decrement here or the counter leaks
            // (spinner stuck on, PTY never freed). Guard >0 so a replaced *completed* action can't underflow.
            TerminalStore.shared.close(prev); actionPTYId = nil
            if activeActions > 0 { activeActions -= 1 }
        }
        let id = TerminalStore.commandPrefix + UUID().uuidString
        actionPTYId = id
        actionRepo = repo
        actionLabel = "docker compose " + verb.joined(separator: " ")
        Docker.cmdCount += 1
        activeActions += 1
        panel.setLoading(true)
        panel.setPeekVisible(true)
        let view = TerminalStore.shared.commandView(id: id, exe: Docker.bin,
                                                    args: ["compose"] + fflags + verb, cwd: repo)
        overlay.setTitle(actionLabel)
        overlay.showTerminal(view)   // mounted but hidden until peek or failure
    }

    private func handleActionExit(_ id: String, _ code: Int32?) {
        guard id == actionPTYId else { return }
        activeActions = max(0, activeActions - 1)
        actingService = nil   // clear the per-row spinner; loadServices() below re-renders with fresh state
        if activeActions == 0 { panel.setLoading(false) }
        // The user may have switched sessions while this ran. An in-flight action belongs to the repo it
        // was started for — if that's no longer the active repo, let it finish silently: don't refresh the
        // now-different list or pop its failure overlay over the wrong repo. Just free the PTY.
        guard actionRepo == composeRepo else { cleanupExitedAction(); return }
        loadServices()                                  // backstop; dots also flip via events
        if (code ?? 0) != 0, isShown { showOverlay() }  // auto-show on failure
    }

    private func showOverlay() { guard actionPTYId != nil else { return }; overlay.reveal() }
    private func hideOverlay() { overlay.dismiss() }

    /// Open logs in a **separate terminal tab** (roomy; the dock is short). `service == nil` → all
    /// services interleaved (Docker prefixes each line with the service name). Backfills `--tail=1000`
    /// then follows. The PTY is keyed directly by the tab id, so `CenterViewController` renders the tab by
    /// reusing this live view (same trick as Quick Ask's fork).
    func openLogs(service: String?) {
        guard let repo = composeRepo, let session = model.activeSession else { return }
        let files = composeFiles.ordered.filter { composeSelected.contains($0) }
        let fflags = files.flatMap { ["-f", $0] }
        let svcArgs = service.map { [$0] } ?? []
        let tab = Tab(kind: .terminal, title: service.map { "logs: \($0)" } ?? "logs: all")
        _ = TerminalStore.shared.commandView(id: tab.id, exe: Docker.bin,
                args: ["compose"] + fflags + ["logs", "--tail=1000", "-f"] + svcArgs, cwd: repo)
        Docker.cmdCount += 1
        session.addTab(tab)
    }

    /// Open an interactive shell **inside** a running service's container as a terminal tab
    /// (`docker compose exec <svc> sh`). The PTY gives it a TTY, so it's fully interactive; exiting the
    /// shell ends the tab's process (normal "Session ended" behavior).
    func openExec(service: String) {
        guard let repo = composeRepo, let session = model.activeSession else { return }
        let files = composeFiles.ordered.filter { composeSelected.contains($0) }
        let fflags = files.flatMap { ["-f", $0] }
        let tab = Tab(kind: .terminal, title: "sh: \(service)")
        _ = TerminalStore.shared.commandView(id: tab.id, exe: Docker.bin,
                args: ["compose"] + fflags + ["exec", service, "sh"], cwd: repo)
        Docker.cmdCount += 1
        session.addTab(tab)
    }

    /// Open a service's published port in the default browser (`http://localhost:<host>`). Useful for web
    /// services; for non-HTTP ports (e.g. a database) the browser just can't speak the protocol — harmless.
    func openPort(_ host: String) {
        guard let url = URL(string: "http://localhost:\(host)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Promote the action PTY to a real terminal tab (its output + scrollback move with it).
    private func openActionAsTab() {
        guard let id = actionPTYId, let session = model.activeSession else { return }
        let tab = Tab(kind: .terminal, title: actionLabel)
        overlay.releaseMounted()   // the view is moving to the tab — drop our ref so a later action can't yank it back
        TerminalStore.shared.promoteCommand(commandID: id, tabID: tab.id)
        session.addTab(tab)
        actionPTYId = nil
        actionRepo = nil
        panel.setPeekVisible(false)
        hideOverlay()
    }

    // MARK: - Volumes (Phase 7)

    private var volumes: [Docker.ComposeVolume] = []
    private var volLoadToken = 0
    private var sizeLoading: Set<String> = []   // volumes whose size is being computed (shows a spinner)

    /// Load the project's volumes (label-scoped). Resolves the project name from `ps` (cached) or the
    /// merged config, so it works even when the stack is down (volumes persist across `down`).
    func loadVolumes() {
        guard let repo = composeRepo else { volumes = []; panel.renderVolumes([], loading: []); return }
        let files = composeFiles.ordered.filter { composeSelected.contains($0) }
        let known = currentProject
        volLoadToken += 1; let token = volLoadToken
        panel.setLoading(true)
        DispatchQueue.global().async { [weak self] in
            let project = known ?? Docker.composeProject(repo: repo, files: files)
            let vols = project.map { Docker.volumes(project: $0) } ?? []
            DispatchQueue.main.async {
                guard let self, token == self.volLoadToken else { return }
                if let project, self.currentProject == nil { self.currentProject = project }
                self.volumes = vols
                self.panel.setLoading(false)
                self.panel.renderVolumes(vols, loading: self.sizeLoading)
            }
        }
    }

    /// Compute a volume's size on demand. Shows a spinner on that row while `system df -v` runs (it scans
    /// disk and can take a few seconds), then replaces it with the value (or "—" if it can't be read).
    func loadVolumeSize(_ name: String) {
        guard !sizeLoading.contains(name) else { return }
        sizeLoading.insert(name)
        panel.renderVolumes(volumes, loading: sizeLoading)
        DispatchQueue.global().async { [weak self] in
            let size = Docker.volumeSize(name: name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sizeLoading.remove(name)
                if let i = self.volumes.firstIndex(where: { $0.name == name }) { self.volumes[i].size = size ?? "—" }
                self.panel.renderVolumes(self.volumes, loading: self.sizeLoading)
            }
        }
    }

    /// Remove an (unused) volume — strong confirm, since it permanently deletes data.
    func removeVolume(_ name: String) {
        DockerConfirm.ask(title: "Delete volume “\(name)”?",
                          info: "This permanently deletes the volume and everything stored in it. This can't be undone.",
                          confirmTitle: "Delete", danger: true) { [weak self] in
            DispatchQueue.global().async {
                let err = Docker.removeVolume(name: name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let err {
                        let a = NSAlert(); a.messageText = "Couldn’t delete “\(name)”"
                        a.informativeText = String(err.suffix(400)); a.alertStyle = .warning
                        a.addButton(withTitle: "OK"); a.runModal()
                    }
                    self.loadVolumes()
                }
            }
        }
    }

    private func showPicker() {
        refreshCompose()
        let vc = ComposeFilePickerViewController()
        vc.configure(files: composeFiles, selected: composeSelected)
        vc.onToggle = { [weak self] file in self?.togglePick(file) }
        vc.onAdd = { [weak self] in self?.showAddFilePanel() }
        pickerPopover.contentViewController = vc
        pickerPopover.behavior = .transient
        let anchor = panel.pickerAnchor
        pickerPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// "Add compose file…" — pick an odd-named compose file from inside the project via the open panel.
    private func showAddFilePanel() {
        guard let repo = composeRepo else { return }
        pickerPopover.performClose(nil)
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = "Choose a compose file inside this project"
        p.directoryURL = URL(fileURLWithPath: repo)
        guard p.runModal() == .OK, let url = p.url else { return }
        if isInsideRepo(url.path) {
            addComposeFile(path: url.path)
        } else {
            let a = NSAlert()
            a.messageText = "That file is outside the project"
            a.informativeText = "Choose a compose file inside this project’s folder."
            a.alertStyle = .warning; a.addButton(withTitle: "OK"); a.runModal()
        }
    }

    // MARK: - Toggle (bottom dock, shared with the quick terminal)

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard model.dockerAvailable, model.activeSession != nil else { return }
        // Share-it: if the quick terminal currently occupies the bottom dock, close it first.
        if let qt = QuickTerminalController.current, qt.isShown, model.settings.quickTermMode == .bottom {
            qt.hide()
        }
        guard let container = CenterViewController.current?.showBottomDock() else { return }
        isShown = true
        events.start()        // listen *before* the snapshot below, so an event during it isn't missed
        mount(in: container)  // mount → loadServices (the snapshot)
    }

    func hide() {
        guard isShown else { return }
        events.stop()
        cleanupExitedAction()
        hideOverlay()
        pickerPopover.performClose(nil)
        panel.removeFromSuperview()
        CenterViewController.current?.hideBottomDock()
        isShown = false
        CenterViewController.current?.focusActiveContent()
    }

    /// Called by the quick terminal when *it* takes over the bottom dock — drop our content without
    /// tearing the dock down (the quick terminal is about to reuse the same container).
    func vacateDock() {
        guard isShown else { return }
        events.stop()
        cleanupExitedAction()
        hideOverlay()
        pickerPopover.performClose(nil)
        panel.removeFromSuperview()
        isShown = false
    }

    /// Free a completed action's PTY when the panel closes (you can't peek a closed panel). An in-flight
    /// action is left alone so it isn't killed mid-run.
    private func cleanupExitedAction() {
        guard activeActions == 0, let id = actionPTYId else { return }
        TerminalStore.shared.close(id)
        actionPTYId = nil
        actionRepo = nil
        overlay.releaseMounted()
        panel.setPeekVisible(false)
    }

    private func mount(in container: NSView) {
        refreshCompose()
        panel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.setComposeLabel(selectionLabel())
        updateActionsEnabled()
        panel.renderServices(services, acting: actingService)   // show cached rows immediately…
        refreshVisible()                 // …then refresh the visible tab (services or volumes) from docker
    }

    // MARK: - Debug

    func debugForceAvailable(_ v: Bool?) { forcedAvailable = v; checkAvailability() }

    /// Open the picker popover (so the screenshot harness can capture it — popovers aren't otherwise
    /// reachable without a real click).
    func debugShowPicker() { guard isShown else { return }; showPicker() }

    func debugRefresh() { refreshCompose(); loadServices() }
    func debugSetTab(_ index: Int) { panel.setMode(index) }
    func debugShowOverlay() { showOverlay() }
    func debugOpenAsTab() { openActionAsTab() }
    /// Force a row into the acting (spinner) state for a deterministic screenshot — the real path clears it
    /// on the action's PTY exit, which is too fast to capture reliably.
    func debugSetActing(_ service: String?) { actingService = service; panel.renderServices(services, acting: actingService) }

    private func servicesDictArray() -> [[String: Any]] {
        services.map { ["name": $0.name, "state": $0.state.rawValue, "ports": $0.ports, "count": $0.count,
                        "links": $0.ports.compactMap { DockerServiceRow.hostPort($0) }.map { "http://localhost:\($0)" }] }
    }

    private func volumesDictArray() -> [[String: Any]] {
        volumes.map { ["name": $0.name, "display": $0.display, "inUse": $0.inUse,
                       "users": $0.users, "size": $0.size ?? NSNull()] }
    }

    func debugStateDict() -> [String: Any] {
        refreshCompose()
        return ["available": model.dockerAvailable, "shown": isShown, "dockVisible": isShown,
                "files": composeFiles.all,
                "selected": composeFiles.ordered.filter { composeSelected.contains($0) },
                "composeCmd": composeCmd,
                "services": servicesDictArray(),
                "eventStreamUp": events.isUp,
                "dockerCmdCount": Docker.cmdCount,
                "overlayVisible": overlay.isPresented,
                "actionRunning": activeActions > 0,
                "actingService": actingService ?? NSNull(),
                "volumes": volumesDictArray(),
                "project": currentProject ?? NSNull()]
    }

    func debugDump() -> String {
        refreshCompose()
        let selected = composeFiles.ordered.filter { composeSelected.contains($0) }
        let svcLines = services.map { "  \($0.name) [\($0.state.rawValue)]\($0.count > 1 ? " ×\($0.count)" : "") ports=\($0.ports.joined(separator: " "))" }
            .joined(separator: "\n")
        return """
        available=\(model.dockerAvailable)
        forced=\(forcedAvailable.map(String.init(describing:)) ?? "nil")
        shown=\(isShown)
        dockVisible=\(isShown)
        project=\(model.activeSession?.name ?? "<none>")
        files=\(composeFiles.all.joined(separator: ","))
        base=\(composeFiles.base ?? "-")
        override=\(composeFiles.override ?? "-")
        variants=\(composeFiles.variants.joined(separator: ","))
        selected=\(selected.joined(separator: ","))
        composeCmd=\(composeCmd)
        eventStreamUp=\(events.isUp)
        dockerCmdCount=\(Docker.cmdCount)
        project=\(currentProject ?? "-")
        visibleMode=\(panel.visibleMode == 1 ? "volumes" : "services")
        overlayVisible=\(overlay.isPresented)
        actionRunning=\(activeActions > 0)
        actingService=\(actingService ?? "-")
        actionLabel=\(actionLabel)
        actionOutput=\(actionPTYId.flatMap { TerminalStore.shared.screenText($0) }?.suffix(400).description ?? "-")
        services:
        \(svcLines.isEmpty ? "  <none>" : svcLines)
        volumes:
        \(volumes.isEmpty ? "  <none>" : volumes.map { "  \($0.display) [\($0.inUse ? "in use" : "unused")] users=\($0.users.joined(separator: ",")) size=\($0.size ?? "-")" }.joined(separator: "\n"))
        """
    }
}

/// Content for the Docker bottom dock: a header (compose-file picker · Services/Volumes toggle ·
/// refresh) over the services list (**Phase 3**). The Volumes tab is a placeholder until Phase 7.
final class DockerPanel: NSView {
    private let composeButton = PointerButton()
    private let modeSeg = PointerSegmentedControl(labels: ["Services", "Volumes"], trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let refreshButton = HoverIconButton()
    private let peekButton = HoverIconButton()
    private let spinner = NSProgressIndicator()
    private var projectButtons: [PointerButton] = []   // up/build/pull/stop/restart/down/all-logs — disabled with no compose file
    private var buildButton = PointerButton()          // project Build — shown only when a service has a build context
    private var pullButton = PointerButton()           // project Pull — shown only when a service is image-based
    private var imagesGroup = NSStackView()            // the Build·Pull cluster (hidden when neither applies)
    private var imagesSep = NSView()                   // divider before the images cluster (hidden with it)

    private let servicesScroll = NSScrollView()
    private let servicesStack = NSStackView()
    private let servicesHeader = NSView()   // column titles above the services list
    private let emptyLabel = NSTextField(labelWithString: "No services")
    private let volumesScroll = NSScrollView()
    private let volumesStack = NSStackView()
    private let volumesHeader = NSView()     // column titles above the volumes list
    private let volumesEmpty = NSTextField(labelWithString: "No volumes")

    /// Alternating-row tint (zebra) so the columns read as a table. Hover (`HoverRow.hoverBG`) sits on top.
    static let stripe = NSColor(white: 1, alpha: 0.035).cgColor

    var onComposeClick: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onServiceAction: ((String, ServiceVerb) -> Void)?
    var onProjectAction: ((ProjectVerb) -> Void)?
    var onServiceLogs: ((String) -> Void)?
    var onServiceExec: ((String) -> Void)?
    var onOpenPort: ((String) -> Void)?
    var onAllLogs: (() -> Void)?
    var onModeChange: ((Int) -> Void)?
    var onVolSize: ((String) -> Void)?
    var onVolRemove: ((String) -> Void)?
    var onPeek: (() -> Void)?
    var pickerAnchor: NSView { composeButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildHeader()
        buildBody()
        setMode(0)
        setComposeLabel("Docker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHeader() {
        composeButton.isBordered = false
        composeButton.bezelStyle = .inline
        composeButton.setButtonType(.momentaryChange)
        composeButton.imagePosition = .imageTrailing
        composeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        composeButton.contentTintColor = NSColor(white: 0.7, alpha: 1)
        composeButton.target = self; composeButton.action = #selector(composeClicked)
        composeButton.toolTip = "Choose which compose file(s) to use"

        modeSeg.selectedSegment = 0
        modeSeg.target = self; modeSeg.action = #selector(modeClicked)

        refreshButton.isBordered = false
        refreshButton.bezelStyle = .inline
        refreshButton.setButtonType(.momentaryChange)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        refreshButton.baseTint = NSColor(white: 0.7, alpha: 1)
        refreshButton.target = self; refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Refresh"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        peekButton.isBordered = false
        peekButton.bezelStyle = .inline
        peekButton.setButtonType(.momentaryChange)
        peekButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "View action output")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        peekButton.baseTint = NSColor(white: 0.7, alpha: 1)
        peekButton.target = self; peekButton.action = #selector(peekClicked)
        peekButton.toolTip = "View the last action's output"
        peekButton.isHidden = true

        // Project-wide actions, grouped into clusters separated by thin dividers: lifecycle · images · logs.
        let up = iconButton("play.fill", "Up — start the whole stack", #selector(upAll))
        buildButton = iconButton("hammer", "Build images (no start)", #selector(buildAll))
        buildButton.isHidden = true   // only shown when at least one service has a build context
        pullButton = iconButton("square.and.arrow.down", "Pull latest images", #selector(pullAll))
        pullButton.isHidden = true    // only shown when at least one service is image-based
        let stop = iconButton("stop.fill", "Stop all services", #selector(stopAll))
        let restart = iconButton("arrow.clockwise", "Restart all services", #selector(restartAll))
        let down = iconButton("arrow.down.circle", "Down — stop & remove containers", #selector(downAll))
        let logs = iconButton("text.alignleft", "All logs (every service)", #selector(allLogs))
        projectButtons = [up, buildButton, pullButton, stop, restart, down, logs]   // enable/disable as a set

        let lifecycle = NSStackView(views: [up, stop, restart, down]); lifecycle.spacing = 12
        imagesGroup = NSStackView(views: [buildButton, pullButton]); imagesGroup.spacing = 12
        imagesSep = vDivider()
        let projectActions = NSStackView(views: [vDivider(), lifecycle, imagesSep, imagesGroup, vDivider(), logs, vDivider()])
        projectActions.spacing = 12
        projectActions.alignment = .centerY
        updateActionGroups()   // hide the images cluster + its divider until something is buildable/pullable

        let header = NSStackView(views: [composeButton, projectActions, NSView(), modeSeg, spinner, peekButton, refreshButton])
        header.spacing = 14
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 22),
        ])
        headerBottom = header.bottomAnchor
    }

    private var headerBottom: NSLayoutYAxisAnchor!

    private func buildBody() {
        servicesStack.orientation = .vertical
        servicesStack.alignment = .leading
        servicesStack.spacing = 1
        servicesStack.translatesAutoresizingMaskIntoConstraints = false

        servicesScroll.drawsBackground = false
        servicesScroll.hasVerticalScroller = true
        servicesScroll.contentView = FlippedClipView()           // anchor content to the top
        servicesScroll.documentView = servicesStack
        servicesScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor(white: 0.45, alpha: 1)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        volumesStack.orientation = .vertical
        volumesStack.alignment = .leading
        volumesStack.spacing = 1
        volumesStack.translatesAutoresizingMaskIntoConstraints = false
        volumesScroll.drawsBackground = false
        volumesScroll.hasVerticalScroller = true
        volumesScroll.contentView = FlippedClipView()
        volumesScroll.documentView = volumesStack
        volumesScroll.translatesAutoresizingMaskIntoConstraints = false
        volumesEmpty.font = .systemFont(ofSize: 12)
        volumesEmpty.textColor = NSColor(white: 0.45, alpha: 1)
        volumesEmpty.translatesAutoresizingMaskIntoConstraints = false

        buildHeaders()
        servicesHeader.translatesAutoresizingMaskIntoConstraints = false
        volumesHeader.translatesAutoresizingMaskIntoConstraints = false

        addSubview(servicesHeader); addSubview(servicesScroll); addSubview(emptyLabel)
        addSubview(volumesHeader); addSubview(volumesScroll); addSubview(volumesEmpty)
        NSLayoutConstraint.activate([
            servicesHeader.topAnchor.constraint(equalTo: headerBottom, constant: 6),
            servicesHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            servicesHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            servicesHeader.heightAnchor.constraint(equalToConstant: 20),
            servicesScroll.topAnchor.constraint(equalTo: servicesHeader.bottomAnchor),
            servicesScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            servicesScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            servicesScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            servicesStack.topAnchor.constraint(equalTo: servicesScroll.contentView.topAnchor),
            servicesStack.leadingAnchor.constraint(equalTo: servicesScroll.contentView.leadingAnchor),
            servicesStack.widthAnchor.constraint(equalTo: servicesScroll.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            volumesHeader.topAnchor.constraint(equalTo: headerBottom, constant: 6),
            volumesHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumesHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumesHeader.heightAnchor.constraint(equalToConstant: 20),
            volumesScroll.topAnchor.constraint(equalTo: volumesHeader.bottomAnchor),
            volumesScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumesScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumesScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            volumesStack.topAnchor.constraint(equalTo: volumesScroll.contentView.topAnchor),
            volumesStack.leadingAnchor.constraint(equalTo: volumesScroll.contentView.leadingAnchor),
            volumesStack.widthAnchor.constraint(equalTo: volumesScroll.contentView.widthAnchor),
            volumesEmpty.centerXAnchor.constraint(equalTo: centerXAnchor),
            volumesEmpty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Column-title rows above each list (with a hairline separator) so the panel reads as a real table.
    private func buildHeaders() {
        func title(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.attributedStringValue = NSAttributedString(string: s, attributes: [
                .foregroundColor: NSColor(white: 0.42, alpha: 1),
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .kern: 0.6])
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        func separator(in v: NSView) {
            let s = NSView(); s.wantsLayer = true
            s.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            s.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                s.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                s.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                s.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        // Services: SERVICE at the name column, PORTS at the fixed ports column (x=200, matching the rows).
        let svcName = title("SERVICE"); let svcPorts = title("PORTS")
        servicesHeader.addSubview(svcName); servicesHeader.addSubview(svcPorts)
        NSLayoutConstraint.activate([
            svcName.leadingAnchor.constraint(equalTo: servicesHeader.leadingAnchor, constant: 34),
            svcName.centerYAnchor.constraint(equalTo: servicesHeader.centerYAnchor, constant: -1),
            svcPorts.leadingAnchor.constraint(equalTo: servicesHeader.leadingAnchor, constant: 200),
            svcPorts.centerYAnchor.constraint(equalTo: servicesHeader.centerYAnchor, constant: -1),
        ])
        separator(in: servicesHeader)
        // Volumes: VOLUME at the name column (x=16), SIZE right-aligned above the size chip.
        let volName = title("VOLUME"); let volSize = title("SIZE")
        volumesHeader.addSubview(volName); volumesHeader.addSubview(volSize)
        NSLayoutConstraint.activate([
            volName.leadingAnchor.constraint(equalTo: volumesHeader.leadingAnchor, constant: 16),
            volName.centerYAnchor.constraint(equalTo: volumesHeader.centerYAnchor, constant: -1),
            volSize.trailingAnchor.constraint(equalTo: volumesHeader.trailingAnchor, constant: -54),
            volSize.centerYAnchor.constraint(equalTo: volumesHeader.centerYAnchor, constant: -1),
        ])
        separator(in: volumesHeader)
    }

    @objc private func composeClicked() { onComposeClick?() }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func modeClicked() { setMode(modeSeg.selectedSegment) }
    @objc private func upAll() { onProjectAction?(.up) }
    @objc private func buildAll() { onProjectAction?(.build) }
    @objc private func pullAll() { onProjectAction?(.pull) }
    @objc private func stopAll() { onProjectAction?(.stop) }
    @objc private func restartAll() { onProjectAction?(.restart) }
    @objc private func downAll() { onProjectAction?(.down) }
    @objc private func allLogs() { onAllLogs?() }
    @objc private func peekClicked() { onPeek?() }

    func setPeekVisible(_ on: Bool) { peekButton.isHidden = !on }
    func setProjectActionsEnabled(_ on: Bool) { projectButtons.forEach { $0.isEnabled = on } }
    func setProjectBuildVisible(_ on: Bool) { buildButton.isHidden = !on; updateActionGroups() }
    func setProjectPullVisible(_ on: Bool) { pullButton.isHidden = !on; updateActionGroups() }
    func setServicesEmptyText(_ s: String) { emptyLabel.stringValue = s }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> PointerButton {
        let b = HoverIconButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.setButtonType(.momentaryChange)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        b.baseTint = NSColor(white: 0.7, alpha: 1)
        b.target = self; b.action = action
        b.toolTip = tip
        return b
    }

    /// A thin vertical divider between header action clusters.
    private func vDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    /// Hide the images cluster (Build·Pull) and its leading divider when nothing is buildable/pullable.
    private func updateActionGroups() {
        let hasImages = !buildButton.isHidden || !pullButton.isHidden
        imagesGroup.isHidden = !hasImages
        imagesSep.isHidden = !hasImages
    }

    func setComposeLabel(_ s: String) {
        composeButton.attributedTitle = NSAttributedString(string: s + " ", attributes: [
            .foregroundColor: NSColor(white: 0.78, alpha: 1),
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
    }

    func setLoading(_ on: Bool) { on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }

    var visibleMode: Int { modeSeg.selectedSegment }

    /// 0 = Services, 1 = Volumes.
    func setMode(_ index: Int) {
        modeSeg.selectedSegment = index
        let services = index == 0
        let svcEmpty = servicesStack.arrangedSubviews.isEmpty
        let volEmpty = volumesStack.arrangedSubviews.isEmpty
        servicesScroll.isHidden = !services
        servicesHeader.isHidden = !services || svcEmpty       // no lone header over an empty list
        emptyLabel.isHidden = !services || !svcEmpty
        volumesScroll.isHidden = services
        volumesHeader.isHidden = services || volEmpty
        volumesEmpty.isHidden = services || !volEmpty
        onModeChange?(index)
    }

    func renderServices(_ services: [Docker.ComposeService], acting: String?) {
        servicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, svc) in services.enumerated() {
            let row = DockerServiceRow(service: svc, acting: svc.name == acting)
            row.onAction = { [weak self] name, verb in self?.onServiceAction?(name, verb) }
            row.onLogs = { [weak self] name in self?.onServiceLogs?(name) }
            row.onExec = { [weak self] name in self?.onServiceExec?(name) }
            row.onOpenPort = { [weak self] host in self?.onOpenPort?(host) }
            row.baseBackground = (i % 2 == 1) ? DockerPanel.stripe : nil
            row.translatesAutoresizingMaskIntoConstraints = false
            servicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: servicesStack.widthAnchor).isActive = true
        }
        let active = modeSeg.selectedSegment == 0
        emptyLabel.isHidden = !active || !services.isEmpty
        servicesHeader.isHidden = !active || services.isEmpty
    }

    func renderVolumes(_ volumes: [Docker.ComposeVolume], loading: Set<String>) {
        volumesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, vol) in volumes.enumerated() {
            let row = DockerVolumeRow(volume: vol, loading: loading.contains(vol.name))
            row.onSize = { [weak self] name in self?.onVolSize?(name) }
            row.onRemove = { [weak self] name in self?.onVolRemove?(name) }
            row.baseBackground = (i % 2 == 1) ? DockerPanel.stripe : nil
            row.translatesAutoresizingMaskIntoConstraints = false
            volumesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: volumesStack.widthAnchor).isActive = true
        }
        let active = modeSeg.selectedSegment == 1
        volumesEmpty.isHidden = !active || !volumes.isEmpty
        volumesHeader.isHidden = !active || volumes.isEmpty
    }
}

/// A list row that highlights its background on hover, so the list feels interactive and the row you're
/// about to act on is obvious. Hover can't be exercised by the screenshot harness (the sandbox blocks
/// synthetic mouse events), so this needs a human to verify.
class HoverRow: NSView {
    /// Base (non-hover) background — the zebra stripe colour, restored on mouse-exit. nil = transparent.
    var baseBackground: CGColor? { didSet { if !hovering { layer?.backgroundColor = baseBackground } } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    private static let hoverBG = NSColor(white: 1, alpha: 0.085).cgColor   // brighter than the stripe

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true;  layer?.backgroundColor = Self.hoverBG }
    override func mouseExited(with event: NSEvent)  { hovering = false; layer?.backgroundColor = baseBackground }
}

/// An icon button that brightens on hover. `PointerButton` only swaps the cursor, so 10pt symbols don't
/// read as buttons; this gives them the expected feedback. Hover is human-verified (see `HoverRow`).
final class HoverIconButton: PointerButton {
    var baseTint = NSColor(white: 0.6, alpha: 1) { didSet { if !hovering { contentTintColor = baseTint } } }
    var hoverTint = NSColor(white: 0.95, alpha: 1)
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true;  if isEnabled { contentTintColor = hoverTint } }
    override func mouseExited(with event: NSEvent)  { hovering = false; contentTintColor = baseTint }
    // No pointing-hand on a disabled button (e.g. the in-use volume's dimmed trash).
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A small pill button (faint fill + border) so a text action like "size" reads as tappable, not as a
/// plain label. Brightens on hover.
final class ChipButton: PointerButton {
    private var tracking: NSTrackingArea?
    private static let base  = NSColor(white: 1, alpha: 0.07).cgColor
    private static let hover = NSColor(white: 1, alpha: 0.14).cgColor

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        isBordered = false; bezelStyle = .inline; setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = Self.base
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor(white: 0.78, alpha: 1),
            .font: NSFont.systemFont(ofSize: 11)])
        self.target = target; self.action = action
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hover }
    override func mouseExited(with event: NSEvent)  { layer?.backgroundColor = Self.base }
}

/// One volume row: name · "in use" (teal) · used-by · size (spinner while computing, then the value,
/// else a clickable "size" chip) · remove (dimmed + disabled when in use, so the size column stays aligned).
final class DockerVolumeRow: HoverRow {
    private let volume: Docker.ComposeVolume
    var onSize: ((String) -> Void)?
    var onRemove: ((String) -> Void)?

    init(volume: Docker.ComposeVolume, loading: Bool) {
        self.volume = volume
        super.init(frame: .zero)
        wantsLayer = true

        let name = NSTextField(labelWithString: volume.display)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = NSColor(white: 0.85, alpha: 1)
        name.translatesAutoresizingMaskIntoConstraints = false

        // Only in-use volumes get a badge, and it's highlighted; unused show nothing.
        let badge = NSTextField(labelWithString: "in use")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .systemTeal
        badge.isHidden = !volume.inUse
        badge.translatesAutoresizingMaskIntoConstraints = false

        // Which service(s) mount it (muted, next to the badge).
        let users = NSTextField(labelWithString: volume.users.isEmpty ? "" : "· " + volume.users.joined(separator: ", "))
        users.font = .systemFont(ofSize: 10)
        users.textColor = NSColor(white: 0.5, alpha: 1)
        users.isHidden = volume.users.isEmpty
        users.lineBreakMode = .byTruncatingTail
        users.translatesAutoresizingMaskIntoConstraints = false

        // Size: a spinner while computing, a plain value once known, else a clickable "size" chip.
        let sizeView: NSView
        if loading {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small
            spin.startAnimation(nil)
            sizeView = spin
        } else if let size = volume.size {
            let lbl = NSTextField(labelWithString: size)
            lbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            lbl.textColor = NSColor(white: 0.7, alpha: 1)
            sizeView = lbl
        } else {
            let b = ChipButton(title: "size", target: self, action: #selector(sizeTapped))
            b.toolTip = "Compute size on disk (scans — may take a moment)"
            b.heightAnchor.constraint(equalToConstant: 19).isActive = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            sizeView = b
        }
        sizeView.translatesAutoresizingMaskIntoConstraints = false

        let remove = HoverIconButton()
        remove.isBordered = false; remove.bezelStyle = .inline; remove.setButtonType(.momentaryChange)
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete volume")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        remove.baseTint = NSColor(white: 0.62, alpha: 1)
        remove.target = self; remove.action = #selector(removeTapped)
        // In-use volumes can't be removed — keep the trash in place but dimmed + disabled so the size
        // column stays aligned across rows (hiding it shifted the size column on in-use rows).
        remove.isEnabled = !volume.inUse
        remove.alphaValue = volume.inUse ? 0.3 : 1
        remove.toolTip = volume.inUse ? "In use — run Down first to delete" : "Delete volume (permanent)"
        remove.translatesAutoresizingMaskIntoConstraints = false

        let trailing = NSStackView(views: [sizeView, remove])
        trailing.spacing = 14; trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(name); addSubview(badge); addSubview(users); addSubview(trailing)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            users.leadingAnchor.constraint(equalTo: badge.isHidden ? name.trailingAnchor : badge.trailingAnchor,
                                           constant: badge.isHidden ? 12 : 6),
            users.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: users.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func sizeTapped()   { onSize?(volume.name) }
    @objc private func removeTapped() { onRemove?(volume.name) }
}

/// One service row: a state dot (filled = up, hollow ring = stopped) · name · `×N` replicas · published
/// ports (fixed column) · state-driven action buttons (Start when stopped; Shell + Stop + Restart when
/// up). Buttons route through `onAction(serviceName, verb)`.
final class DockerServiceRow: HoverRow {
    private let service: Docker.ComposeService
    var onAction: ((String, ServiceVerb) -> Void)?
    var onLogs: ((String) -> Void)?
    var onExec: ((String) -> Void)?
    var onOpenPort: ((String) -> Void)?   // host port → open http://localhost:<port>

    init(service: Docker.ComposeService, acting: Bool) {
        self.service = service
        super.init(frame: .zero)
        wantsLayer = true

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let dotColor = DockerServiceRow.color(for: service.state)
        if service.state == .stopped {        // hollow ring so state reads without relying on colour alone
            dot.layer?.backgroundColor = NSColor.clear.cgColor
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = dotColor.cgColor
        } else {
            dot.layer?.backgroundColor = dotColor.cgColor
        }
        dot.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: service.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = NSColor(white: 0.85, alpha: 1)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false

        // Replica count, only when a service is scaled to >1 container. Muted grey — teal is reserved for
        // the volumes' "in use" badge, so the two stop competing for the same colour meaning.
        let replicas = NSTextField(labelWithString: service.count > 1 ? "×\(service.count)" : "")
        replicas.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        replicas.textColor = NSColor(white: 0.55, alpha: 1)
        replicas.isHidden = service.count <= 1
        replicas.setContentCompressionResistancePriority(.required, for: .horizontal)
        replicas.translatesAutoresizingMaskIntoConstraints = false

        let nameGroup = NSStackView(views: [name, replicas])
        nameGroup.spacing = 6
        nameGroup.alignment = .firstBaseline
        nameGroup.translatesAutoresizingMaskIntoConstraints = false

        // Each published port (`host->container`) is a clickable link → opens http://localhost:<host>.
        // Internal-only ports (no host mapping) stay as plain muted text.
        let ports = NSStackView()
        ports.orientation = .horizontal
        ports.spacing = 10
        ports.translatesAutoresizingMaskIntoConstraints = false
        ports.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for p in service.ports {
            if let host = DockerServiceRow.hostPort(p) {
                let b = PointerButton()
                b.isBordered = false; b.bezelStyle = .inline; b.setButtonType(.momentaryChange)
                b.attributedTitle = NSAttributedString(string: p, attributes: [
                    .foregroundColor: NSColor.linkColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
                b.toolTip = "Open http://localhost:\(host)"
                b.target = self; b.action = #selector(portTapped(_:))
                b.identifier = NSUserInterfaceItemIdentifier(host)   // carry the host port to the handler
                ports.addArrangedSubview(b)
            } else {
                let l = NSTextField(labelWithString: p)
                l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                l.textColor = NSColor(white: 0.55, alpha: 1)
                ports.addArrangedSubview(l)
            }
        }

        // While this service's action is in flight, replace its buttons with a spinner — immediate
        // feedback on the exact row, and you can't double-fire the action (no buttons to click).
        let trailing: NSView
        if acting {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small
            spin.startAnimation(nil)
            spin.translatesAutoresizingMaskIntoConstraints = false
            trailing = spin
        } else {
            // Buttons are ordered so **logs is always rightmost** — the one button every row has, giving a
            // stable right-hand column across rows. Left→right: image action (Build if it builds, else Pull)
            // · lifecycle · shell (running only) · logs. Build/Rebuild show only for services with a build
            // context; Pull only for image-based ones (`!hasBuild`) so neither appears as a no-op.
            var buttons: [PointerButton] = []
            if service.hasBuild {
                buttons += [actionButton("hammer", "Build (no start)", #selector(buildTapped))]
            } else {
                buttons += [actionButton("square.and.arrow.down", "Pull — download the latest image", #selector(pullTapped))]
            }
            if service.state == .stopped {
                buttons += [actionButton("play.fill", "Start", #selector(startTapped))]
                if service.hasBuild {
                    buttons += [actionButton("arrow.triangle.2.circlepath", "Rebuild & start", #selector(startBuildTapped))]
                }
            } else {
                buttons += [actionButton("stop.fill", "Stop", #selector(stopTapped)),
                            actionButton("arrow.clockwise", "Restart", #selector(restartTapped)),
                            actionButton("terminal", "Shell into container", #selector(execTapped))]
            }
            buttons += [actionButton("text.alignleft", "Logs", #selector(logsTapped))]   // always last → rightmost
            let actions = NSStackView(views: buttons)
            actions.spacing = 12
            actions.translatesAutoresizingMaskIntoConstraints = false
            trailing = actions
        }

        addSubview(dot); addSubview(nameGroup); addSubview(ports); addSubview(trailing)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameGroup.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Fixed ports column so the list reads as a table, not a ragged left-pack. Long names truncate.
            ports.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 200),
            ports.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameGroup.trailingAnchor.constraint(lessThanOrEqualTo: ports.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            ports.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func actionButton(_ symbol: String, _ tip: String, _ sel: Selector) -> PointerButton {
        let b = HoverIconButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.setButtonType(.momentaryChange)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        b.baseTint = NSColor(white: 0.6, alpha: 1)
        b.target = self; b.action = sel
        b.toolTip = tip
        return b
    }

    @objc private func startTapped()      { onAction?(service.name, .start) }
    @objc private func stopTapped()       { onAction?(service.name, .stop) }
    @objc private func restartTapped()    { onAction?(service.name, .restart) }
    @objc private func buildTapped()      { onAction?(service.name, .build) }
    @objc private func startBuildTapped() { onAction?(service.name, .startBuild) }
    @objc private func pullTapped()       { onAction?(service.name, .pull) }
    @objc private func logsTapped()       { onLogs?(service.name) }
    @objc private func execTapped()       { onExec?(service.name) }
    @objc private func portTapped(_ sender: NSButton) { sender.identifier.map { onOpenPort?($0.rawValue) } }

    /// The host (published) port from a `host->container` mapping, e.g. "15432->5432" → "15432" and
    /// "0.0.0.0:15432->5432/tcp" → "15432". Returns nil for internal-only ports (no host mapping).
    static func hostPort(_ p: String) -> String? {
        guard let arrow = p.range(of: "->") else { return nil }
        var host = String(p[p.startIndex..<arrow.lowerBound])
        if let colon = host.lastIndex(of: ":") { host = String(host[host.index(after: colon)...]) }
        host = host.trimmingCharacters(in: .whitespaces)
        return (!host.isEmpty && host.allSatisfy(\.isNumber)) ? host : nil
    }

    static func color(for s: Docker.ServiceState) -> NSColor {
        switch s {
        case .running:  return .systemGreen
        case .starting: return .systemYellow
        case .stopped:  return NSColor(white: 0.40, alpha: 1)
        case .other:    return .systemGray
        }
    }
}

/// The peek overlay for a slow action: a small floating panel near the bottom of the window hosting the
/// action's live PTY, with a title, "open as tab", and close. Installed into the window root once (hidden);
/// `reveal()`/`dismiss()` toggle it. Auto-revealed by the controller when an action fails.
final class DockerActionOverlay: NSView {
    private let box = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentBox = NSView()
    private var mounted: NSView?

    var onClose: (() -> Void)?
    var onOpenAsTab: (() -> Void)?
    private(set) var isPresented = false

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0.30, alpha: 1).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        titleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = NSColor(white: 0.78, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let openTab = iconButton("arrow.up.right.square", "Open as tab", #selector(openTabTapped))
        let close = iconButton("xmark", "Close", #selector(closeTapped))
        let header = NSStackView(views: [titleLabel, NSView(), openTab, close])
        header.spacing = 10; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        contentBox.wantsLayer = true
        contentBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor
        contentBox.layer?.cornerRadius = 6
        contentBox.layer?.masksToBounds = true
        contentBox.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(header); box.addSubview(contentBox)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 20),
            contentBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            contentBox.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            contentBox.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            contentBox.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func install(in root: NSView) {
        guard superview == nil else { return }
        root.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: root.centerXAnchor),
            widthAnchor.constraint(equalToConstant: 680),
            heightAnchor.constraint(equalToConstant: 240),
            bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -70),
        ])
    }

    func setTitle(_ s: String) { titleLabel.stringValue = s }

    func showTerminal(_ view: NSView) {
        if mounted === view { return }
        mounted?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentBox.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])
        mounted = view
    }

    func reveal() { superview?.addSubview(self); isHidden = false; isPresented = true }   // re-add = bring to front
    func dismiss() { isHidden = true; isPresented = false }

    /// Drop our reference to the hosted view *without* removing it — used when the view is re-parented
    /// elsewhere (open-as-tab), so a later `showTerminal` doesn't tear it out of its new home.
    func releaseMounted() { mounted = nil }

    @objc private func openTabTapped() { onOpenAsTab?() }
    @objc private func closeTapped() { onClose?() }

    private func iconButton(_ symbol: String, _ tip: String, _ sel: Selector) -> PointerButton {
        let b = PointerButton()
        b.isBordered = false; b.bezelStyle = .inline; b.setButtonType(.momentaryChange)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        b.contentTintColor = NSColor(white: 0.7, alpha: 1)
        b.target = self; b.action = sel; b.toolTip = tip
        return b
    }
}

/// The compose-file picker: a checklist popover. Each detected file is a checkbox; toggling routes back
/// to the controller (which persists). Base/override are tagged; variants show their filename.
/// (The "+ Add compose file…" escape hatch for odd-named files is a later refinement.)
final class ComposeFilePickerViewController: NSViewController {
    private var rows: [(file: String, display: String, tag: String)] = []
    private var checked: Set<String> = []
    var onToggle: ((String) -> Void)?
    var onAdd: (() -> Void)?

    func configure(files: Docker.ComposeFiles, selected: Set<String>) {
        rows = []
        if let b = files.base { rows.append((b, b, "base")) }
        if let o = files.override { rows.append((o, o, "override")) }
        for v in files.variants { rows.append((v, v, "")) }
        for e in files.extras { rows.append((e, (e as NSString).lastPathComponent, "added")) }
        checked = selected
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if rows.isEmpty {
            let l = NSTextField(labelWithString: "No compose file in this folder")
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(l)
        }
        for row in rows {
            let title = row.tag.isEmpty ? row.display : "\(row.display)   (\(row.tag))"
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
            cb.state = checked.contains(row.file) ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(row.file)
            stack.addArrangedSubview(cb)
        }

        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        let add = PointerButton(title: "Add compose file…", target: self, action: #selector(addTapped))
        add.isBordered = false; add.contentTintColor = .controlAccentColor
        add.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(add)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        let rowCount = max(1, rows.count)
        preferredContentSize = NSSize(width: 320, height: 20 + rowCount * 25 + 40)   // +40 for separator + add row
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let file = sender.identifier?.rawValue else { return }
        onToggle?(file)
    }

    @objc private func addTapped() { onAdd?() }
}
