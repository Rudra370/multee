import AppKit
import Combine
import UserNotifications

/// Settings window: native checkboxes / stepper / text field bound to `Settings` (UserDefaults),
/// plus toggleable preset chips for the default Claude args. ESC closes it.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private var fontLabel: NSTextField!
    private var stepper: NSStepper!
    private var argsField: NSTextField!
    private var chipButtons: [(flag: String, button: NSButton)] = []
    private var notifyStatus: NSStackView!     // "macOS notifications are off" warning (hidden when on)
    private var escMonitor: Any?

    private let suggestions = ["--continue", "--resume", "--dangerously-skip-permissions", "--verbose"]

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()

        // ESC closes the settings window (a local monitor catches it even when a field is focused).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }

    private func buildContent() -> NSView {
        let autoLaunch = checkbox("Auto-launch Claude when opening a project", \.autoLaunchClaude)
        let expand = checkbox("Show contents of gitignored folders", \.expandIgnored)
        let sound = checkbox("Play a sound on attention / completion", \.soundEnabled)
        let notify = checkbox("Notify when a background session needs you", \.notificationsEnabled)
        notifyStatus = makeNotifyStatusRow()
        let restore = checkbox("Restore sessions & tabs on launch", \.restoreOnLaunch)
        let monitor = checkbox("Show resource usage (memory / CPU) in the title bar", \.showResourceMonitor)

        stepper = NSStepper()
        stepper.minValue = 9; stepper.maxValue = 24; stepper.increment = 1
        stepper.integerValue = Int(settings.fontSize)
        stepper.target = self; stepper.action = #selector(fontChanged)
        fontLabel = NSTextField(labelWithString: "Font size: \(Int(settings.fontSize)) pt")
        fontLabel.font = .systemFont(ofSize: 13)
        let fontRow = NSStackView(views: [fontLabel, stepper])
        fontRow.orientation = .horizontal; fontRow.spacing = 8

        let argsLabel = NSTextField(labelWithString: "Default Claude args")
        argsLabel.font = .systemFont(ofSize: 13)
        argsField = NSTextField(string: settings.defaultClaudeArgs)
        argsField.placeholderString = "e.g. --dangerously-skip-permissions"
        argsField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        argsField.target = self; argsField.action = #selector(argsChanged)
        argsField.widthAnchor.constraint(equalToConstant: 392).isActive = true

        // Toggleable preset chips.
        let chipRow = NSStackView()
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        for flag in suggestions {
            let b = PointerButton()
            b.title = flag
            b.isBordered = false
            b.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.target = self
            b.action = #selector(chipTapped(_:))
            b.tag = suggestions.firstIndex(of: flag)!
            chipButtons.append((flag, b))
            chipRow.addArrangedSubview(b)
        }
        refreshChips()

        let argsStack = NSStackView(views: [argsLabel, argsField, chipRow])
        argsStack.orientation = .vertical
        argsStack.alignment = .leading
        argsStack.spacing = 8

        let stack = NSStackView(views: [autoLaunch, expand, sound, notify, notifyStatus, restore, monitor, fontRow, argsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
        ])
        return host
    }

    /// A warning row shown under the notify checkbox when macOS notifications aren't allowed for Multee.
    /// Hidden (collapsed) when they are. Indented to sit under the checkbox text.
    private func makeNotifyStatusRow() -> NSStackView {
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                 accessibilityDescription: nil) ?? NSImage())
        warning.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: "macOS notifications are turned off — banners won’t appear.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.7, alpha: 1)
        let open = PointerButton()
        open.isBordered = false
        open.target = self
        open.action = #selector(openNotificationSettings)
        open.attributedTitle = NSAttributedString(string: "Open System Settings…", attributes: [
            .foregroundColor: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.96, alpha: 1),
            .font: NSFont.systemFont(ofSize: 11),
        ])
        let row = NSStackView(views: [warning, label, open])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)   // indent under the checkbox
        row.isHidden = true   // shown after the async authorization check
        return row
    }

    /// Show the warning row only when notifications aren't authorized. Async (UNUserNotificationCenter).
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self?.notifyStatus?.isHidden = allowed
            }
        }
    }

    @objc private func openNotificationSettings() {
        // Deep-link to the Notifications pane; ids differ across macOS versions, so try newest first.
        for s in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                  "x-apple.systempreferences:com.apple.preference.notifications"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshNotificationStatus()   // re-check each time it opens (the user may have just changed it)
    }

    /// Re-check when the window regains focus — e.g. the user toggled the OS permission in System
    /// Settings (via the link above) and clicked back, with this window still open.
    func windowDidBecomeKey(_ notification: Notification) { refreshNotificationStatus() }

    private func checkbox(_ title: String, _ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> NSButton {
        let b = PointerButton(checkboxWithTitle: title, target: self, action: #selector(toggle(_:)))
        b.state = settings[keyPath: keyPath] ? .on : .off
        keyPaths[ObjectIdentifier(b)] = keyPath
        return b
    }
    private var keyPaths: [ObjectIdentifier: ReferenceWritableKeyPath<Settings, Bool>] = [:]

    @objc private func toggle(_ sender: NSButton) {
        guard let kp = keyPaths[ObjectIdentifier(sender)] else { return }
        settings[keyPath: kp] = sender.state == .on
    }
    @objc private func fontChanged() {
        settings.fontSize = Double(stepper.integerValue)
        fontLabel.stringValue = "Font size: \(stepper.integerValue) pt"
    }
    @objc private func argsChanged() { settings.defaultClaudeArgs = argsField.stringValue; refreshChips() }

    @objc private func chipTapped(_ sender: NSButton) {
        let flag = suggestions[sender.tag]
        var parts = settings.defaultClaudeArgs.split(separator: " ").map(String.init)
        if let i = parts.firstIndex(of: flag) { parts.remove(at: i) } else { parts.append(flag) }
        settings.defaultClaudeArgs = parts.joined(separator: " ")
        argsField.stringValue = settings.defaultClaudeArgs
        refreshChips()
    }

    private func refreshChips() {
        let active = Set(settings.defaultClaudeArgs.split(separator: " ").map(String.init))
        for (flag, b) in chipButtons {
            let on = active.contains(flag)
            b.layer?.backgroundColor = (on ? NSColor(red: 0.04, green: 0.28, blue: 0.44, alpha: 1)
                                           : NSColor(white: 0.22, alpha: 1)).cgColor
            b.contentTintColor = on ? .white : NSColor(white: 0.75, alpha: 1)
        }
    }
}
