import AppKit
import Combine

/// Lightweight update checker: asks GitHub for the latest release and, if it's newer than the
/// running build, surfaces a banner. "Install now" runs `brew upgrade` non-interactively in an in-app
/// terminal (opening one in the home folder if no session is open), then auto-relaunches into the new
/// build when it succeeds (no Sparkle / appcast / signing needed). "Download" opens the release page when
/// the app isn't brew-managed. (`isDev` lives in AppDelegate.)
final class Updates: ObservableObject {
    static let shared = Updates()

    @Published var latest: String?        // newer version e.g. "0.2.0"; nil when up to date / unknown
    @Published var notes: String?         // the new release's description (GitHub release body)
    @Published var dismissed = false      // user hit "Later"
    @Published var installing = false     // brew upgrade kicked off → offer Relaunch
    @Published var installFailed = false  // the update command failed/timed out → offer Retry
    /// The failure was our own alarm firing, not an error from brew/git — the update was *working*, just
    /// slower than its budget, so the banner says so instead of blaming the network.
    @Published var installTimedOut = false
    @Published var brewManaged = false    // app was installed via the Homebrew cask
    private var checking = false
    private var autoCheckTimer: Timer?
    private var lastCheck: Date?
    private let snoozeDuration: TimeInterval = 24 * 3600   // "Later" hides the banner for a day

    // "Later" snooze, persisted so quitting/reopening within the window doesn't re-pop the banner.
    private var snoozeVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSnoozeVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSnoozeVersion") }
    }
    private var snoozeUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "updateSnoozeUntil")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "updateSnoozeUntil") }
    }

    /// Is `version` still inside its "Later" snooze window? A different (newer) version is never snoozed.
    private func isSnoozed(_ version: String) -> Bool {
        guard version == snoozeVersion, let until = snoozeUntil else { return false }
        return Date() < until
    }

    let repo = "Rudra370/multee"
    let caskRef = "Rudra370/tap/multee"
    let tapRef = "Rudra370/tap"           // the cask's tap — refreshed alone, never a global `brew update`

    private init() {}

    var current: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    var showBanner: Bool { latest != nil && !dismissed }
    var releasePage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    func detectBrew() {
        DispatchQueue.global(qos: .utility).async {
            let brew = Env.resolve("brew")
            var managed = false
            if brew.contains("/") {
                let list = Shell.run(brew, ["list", "--cask"])
                managed = list.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "multee" }
            }
            DispatchQueue.main.async { self.brewManaged = managed }
        }
    }

    /// Start periodic background update checks (release builds). Fires an immediate check, then every
    /// `interval`, and re-checks when the app is reactivated if it's been a while — Multee is meant to
    /// stay open for days, and a launch-only check would never see a release published mid-session.
    /// Idempotent.
    func startAutoCheck(interval: TimeInterval = 6 * 3600) {
        guard autoCheckTimer == nil else { return }
        check()
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        // Backstop the timer: a Timer fire-date that elapses during sleep is unreliable, so also probe
        // on reactivation, throttled so returning to the app doesn't hammer the GitHub API.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appBecameActive() {
        if let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        check()
    }

    func check(force: Bool = false) {
        // Skip background checks while an install is mid-flight (it'd disrupt the banner); manual still runs.
        guard !checking, force || !installing else { return }
        checking = true
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let cur = current
        URLSession.shared.dataTask(with: req) { data, resp, error in
            // Did we actually hear back from GitHub? A failed request (offline, timeout, rate-limit/non-2xx,
            // unparseable body) must NOT be reported as "up to date" — only a clean 2xx with a parseable tag is.
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var newer: String?
            var body: String?
            var reached = false
            if error == nil, (200..<300).contains(status), let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                reached = true
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Updates.isNewer(v, than: cur) { newer = v; body = (obj["body"] as? String) }
            }
            DispatchQueue.main.async {
                self.checking = false
                self.lastCheck = Date()
                if let newer {
                    self.latest = newer
                    self.notes = body?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.installFailed = false   // a fresh availability supersedes a stale prior failure
                    // Show unless this version is still inside its "Later" snooze window. Once the snooze
                    // expires the next check re-surfaces it; a genuinely newer version is never snoozed.
                    self.dismissed = self.isSnoozed(newer)
                } else if force {
                    // Manual check: tell the truth — up to date only if we reached GitHub, else it failed.
                    if reached { self.latest = nil; self.upToDateAlert() } else { self.checkFailedAlert() }
                }
                // Background (non-force) failures stay silent; the next periodic check retries.
            }
        }.resume()
    }

    func installNow(app: AppModel) {
        // No session open? Open a bare terminal in the home folder so the update runs with nothing open.
        let session = app.activeSession ?? app.openRepo(NSHomeDirectory(), autoLaunchClaude: false)
        let tab = Tab(kind: .terminal, title: "Update")
        session.addTab(tab)
        let appPath = Bundle.main.bundlePath
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("multee-update-\(UUID().uuidString)")
        let okFlag = base + ".done", failFlag = base + ".fail", timeoutFlag = base + ".timeout"
        let command = updateCommand(appPath: appPath, ok: okFlag, fail: failFlag, timedOut: timeoutFlag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            TerminalStore.shared.send(tab.id, command)
            self.watchForCompletion(ok: okFlag, fail: failFlag, timedOut: timeoutFlag)
        }
        installing = true
        installFailed = false
        installTimedOut = false
        dismissed = false
    }

    /// The shell chain the Update tab runs. Extracted so the dev harness can dump it verbatim
    /// (`dumpUpdateCmd`) — the quoting and the exit-code→marker branch are otherwise invisible until a real
    /// update runs.
    func updateCommand(appPath: String, ok: String, fail: String, timedOut: String) -> String {
        // Refresh ONLY our tap (a global `brew update` re-fetches every tap, so an unrelated/slow one can
        // hang the update — see DECISIONS). `HOMEBREW_NO_AUTO_UPDATE=1` keeps `brew upgrade` from doing its
        // own global update too. `perl alarm` is a portable timeout (macOS has no `timeout`) — a backstop
        // against a *frozen* brew, deliberately generous: on a link where dual-stack connects stall ~10s
        // each (Happy-Eyeballs fallback), a cold cask download legitimately takes minutes, and the old 180s
        // cap killed working updates (the download is silent, so it looked hung — see DECISIONS D31).
        // `brew fetch` first so the (slow) download happens under its own budget and the upgrade that
        // follows is near-instant from the cache. `--verbose` keeps curl's progress meter on screen instead
        // of a frozen-looking terminal. `--force` reinstalls even if brew is unsure; `xattr` clears the new
        // app's quarantine.
        // Exactly one marker is written: `.done` on full success → auto-relaunch; `.timeout` when a step hit
        // its alarm (SIGALRM → 128+14); `.fail` on any other failure/cancel. Both failures offer Retry.
        let timeout = "perl -e 'alarm shift @ARGV; exec @ARGV'"
        let brewEnv = "env HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1"
        // `{ … } < /dev/null` gives the whole chain a non-TTY stdin, so Homebrew's confirmation prompt is
        // skipped (`Ask.confirm?` returns false off a TTY — `NONINTERACTIVE` alone does NOT gate it) and git
        // can't block on a credential prompt either. Homebrew 6 also turned that prompt *on by default*
        // (`--no-ask` opts out), and merely reaching it costs a full dry-run planning pass — so pass
        // `--no-ask` when this brew knows the flag (older brews would reject an unknown option).
        return "TAP=\"$(brew --repository \(tapRef))\"; "
            + "NOASK=$(brew upgrade --help 2>/dev/null | grep -q -- '--no-ask' && echo --no-ask); { "
            + "echo '==> Updating Multee — this can take a few minutes on a slow connection' "
            + "&& \(timeout) 30 git -C \"$TAP\" fetch --quiet origin HEAD "
            + "&& git -C \"$TAP\" reset --quiet --hard FETCH_HEAD "
            + "&& \(timeout) 600 \(brewEnv) brew fetch --cask --verbose \(caskRef) "
            + "&& \(timeout) 600 \(brewEnv) brew upgrade --cask --force --verbose $NOASK \(caskRef) "
            + "&& xattr -dr com.apple.quarantine '\(appPath)' "
            + "&& touch '\(ok)'; } < /dev/null "
            + "|| { s=$?; if [ \"$s\" = 142 ]; then touch '\(timedOut)'; else touch '\(fail)'; fi; }\n"
    }

    /// Poll for the marker the update command writes: `.done` → relaunch into the new build; `.timeout` /
    /// `.fail` → surface a failed state so the banner offers Retry. The fallback deadline sits above the
    /// command's own budget (fetch + upgrade, 600s each) so a slow-but-working update is never declared dead
    /// while its terminal is still going; it only catches a closed tab / killed shell.
    private var updateWatch: Timer?
    private func watchForCompletion(ok: String, fail: String, timedOut: String) {
        updateWatch?.invalidate()
        let deadline = Date().addingTimeInterval(1500)
        updateWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let fm = FileManager.default
            let markers = [ok, fail, timedOut]
            if fm.fileExists(atPath: ok) {
                t.invalidate()
                markers.forEach { try? fm.removeItem(atPath: $0) }
                self.relaunch()
            } else if fm.fileExists(atPath: fail) || fm.fileExists(atPath: timedOut) || Date() > deadline {
                t.invalidate()
                self.installTimedOut = fm.fileExists(atPath: timedOut)
                markers.forEach { try? fm.removeItem(atPath: $0) }
                self.installing = false
                self.installFailed = true
            }
        }
    }

    /// "Later": hide the banner and snooze this version for 24h (persisted across launches), so it comes
    /// back on its own instead of staying hidden until relaunch / a newer release.
    func dismissBanner() {
        snoozeVersion = latest
        snoozeUntil = Date().addingTimeInterval(snoozeDuration)
        dismissed = true
    }

    func download() { NSWorkspace.shared.open(releasePage) }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func upToDateAlert() {
        let a = NSAlert()
        a.messageText = "You're up to date"
        a.informativeText = "Multee \(current) is the latest version."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func checkFailedAlert() {
        let a = NSAlert()
        a.messageText = "Couldn’t check for updates"
        a.informativeText = "Multee couldn’t reach GitHub. Check your connection and try again."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Numeric semver comparison ("0.2.0" > "0.1.10").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }
}

/// Thin banner shown atop the window when a newer release exists.
final class UpdateBannerView: NSView {
    private let updates: Updates
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let whatsNew = NSButton()
    private var heightConstraint: NSLayoutConstraint!

    init(updates: Updates, model: AppModel) {
        self.updates = updates
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.13, green: 0.30, blue: 0.50, alpha: 1).cgColor

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white

        whatsNew.title = "What's new"
        whatsNew.bezelStyle = .inline; whatsNew.isBordered = false
        whatsNew.contentTintColor = .white
        whatsNew.target = self; whatsNew.action = #selector(showNotes)

        actionButton.bezelStyle = .rounded; actionButton.controlSize = .small
        actionButton.target = self; actionButton.action = #selector(primaryAction)

        let later = NSButton(title: "Later", target: self, action: #selector(dismiss))
        later.bezelStyle = .inline; later.isBordered = false; later.contentTintColor = .white

        let stack = NSStackView(views: [label, NSView(), whatsNew, actionButton, later])
        stack.orientation = .horizontal; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true

        updates.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let show = updates.showBanner
        heightConstraint.constant = show ? 30 : 0
        isHidden = !show
        guard show else { return }
        if updates.installing {
            label.stringValue = "Updating Multee…"
            actionButton.title = "Relaunch"
            whatsNew.isHidden = true
        } else if updates.installFailed {
            label.stringValue = updates.installTimedOut ? "Update timed out — slow connection"
                                                         : "Update failed — couldn’t reach GitHub"
            actionButton.title = "Retry"
            whatsNew.isHidden = true
        } else {
            label.stringValue = "Multee \(updates.latest ?? "") is available"
            actionButton.title = updates.brewManaged ? "Install now" : "Download"
            whatsNew.isHidden = (updates.notes?.isEmpty ?? true)
        }
    }

    @objc private func primaryAction() {
        if updates.installing { updates.relaunch() }
        else if updates.installFailed { updates.installNow(app: model) }   // Retry
        else if updates.brewManaged { updates.installNow(app: model) }
        else { updates.download() }
    }
    @objc private func dismiss() { updates.dismissBanner() }
    @objc private func showNotes() {
        let a = NSAlert()
        a.messageText = "What's new in Multee \(updates.latest ?? "")"
        a.informativeText = updates.notes ?? "No notes."
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
