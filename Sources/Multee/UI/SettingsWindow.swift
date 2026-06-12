import AppKit
import Combine

/// Settings window: native checkboxes / stepper / text field bound to `Settings` (UserDefaults),
/// plus toggleable preset chips for the default Claude args. ESC closes it.
final class SettingsWindowController: NSWindowController {
    private let settings: Settings
    private var fontLabel: NSTextField!
    private var stepper: NSStepper!
    private var argsField: NSTextField!
    private var chipButtons: [(flag: String, button: NSButton)] = []
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
        let restore = checkbox("Restore sessions & tabs on launch", \.restoreOnLaunch)

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

        let stack = NSStackView(views: [autoLaunch, expand, sound, restore, fontRow, argsStack])
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
