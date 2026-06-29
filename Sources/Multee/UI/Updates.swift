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
        let flag = (NSTemporaryDirectory() as NSString).appendingPathComponent("multee-update-\(UUID().uuidString).done")
        // NONINTERACTIVE + --force so Homebrew never stops for a Y/N; `xattr` clears the new app's quarantine;
        // the flag is written only on full success → Multee then auto-relaunches into the new build.
        let command = "NONINTERACTIVE=1 brew update && NONINTERACTIVE=1 brew upgrade --cask --force \(caskRef)"
            + " && xattr -dr com.apple.quarantine '\(appPath)' && touch '\(flag)'\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            TerminalStore.shared.send(tab.id, command)
            self.watchForCompletion(flag: flag)
        }
        installing = true
        dismissed = false
    }

    /// Poll for the success flag the update command writes; when it appears, relaunch into the new build.
    private var updateWatch: Timer?
    private func watchForCompletion(flag: String) {
        updateWatch?.invalidate()
        let deadline = Date().addingTimeInterval(900)   // give up after 15 min (failed/cancelled)
        updateWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if FileManager.default.fileExists(atPath: flag) {
                t.invalidate()
                try? FileManager.default.removeItem(atPath: flag)
                self.relaunch()
            } else if Date() > deadline {
                t.invalidate()
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
        } else {
            label.stringValue = "Multee \(updates.latest ?? "") is available"
            actionButton.title = updates.brewManaged ? "Install now" : "Download"
            whatsNew.isHidden = (updates.notes?.isEmpty ?? true)
        }
    }

    @objc private func primaryAction() {
        if updates.installing { updates.relaunch() }
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
