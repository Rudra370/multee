import AppKit
import Combine

/// Lightweight update checker: asks GitHub for the latest release and, if it's newer than the
/// running build, surfaces a banner. "Install now" runs `brew upgrade` in an in-app terminal (no
/// Sparkle / appcast / signing needed). Falls back to opening the release page. (`isDev` lives in
/// AppDelegate.)
final class Updates: ObservableObject {
    static let shared = Updates()

    @Published var latest: String?        // newer version e.g. "0.2.0"; nil when up to date / unknown
    @Published var notes: String?         // the new release's description (GitHub release body)
    @Published var dismissed = false      // user hit "Later"
    @Published var installing = false     // brew upgrade kicked off → offer Relaunch
    @Published var brewManaged = false    // app was installed via the Homebrew cask
    private var checking = false

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

    func check(force: Bool = false) {
        guard !checking else { return }
        checking = true
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let cur = current
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var newer: String?
            var body: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Updates.isNewer(v, than: cur) { newer = v; body = (obj["body"] as? String) }
            }
            DispatchQueue.main.async {
                self.checking = false
                if let newer {
                    self.latest = newer
                    self.notes = body?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.dismissed = false
                } else if force {
                    self.latest = nil
                    self.upToDateAlert()
                }
            }
        }.resume()
    }

    func installNow(app: AppModel) {
        guard let session = app.activeSession else { download(); return }
        let tab = Tab(kind: .terminal, title: "Update")
        session.addTab(tab)
        let appPath = Bundle.main.bundlePath
        let command = "brew update && brew upgrade --cask \(caskRef) && xattr -dr com.apple.quarantine '\(appPath)'\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            TerminalStore.shared.send(tab.id, command)
        }
        installing = true
        dismissed = false
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
    @objc private func dismiss() { updates.dismissed = true }
    @objc private func showNotes() {
        let a = NSAlert()
        a.messageText = "What's new in Multee \(updates.latest ?? "")"
        a.informativeText = updates.notes ?? "No notes."
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
