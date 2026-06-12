import AppKit
import Combine

/// Settings window: native checkboxes / stepper / text field bound to `Settings` (UserDefaults).
final class SettingsWindowController: NSWindowController {
    private let settings: Settings
    private var fontLabel: NSTextField!
    private var stepper: NSStepper!
    private var argsField: NSTextField!

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        let argsLabel = NSTextField(labelWithString: "Default Claude args:")
        argsLabel.font = .systemFont(ofSize: 13)
        argsField = NSTextField(string: settings.defaultClaudeArgs)
        argsField.placeholderString = "e.g. --dangerously-skip-permissions"
        argsField.target = self; argsField.action = #selector(argsChanged)
        argsField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let argsRow = NSStackView(views: [argsLabel, argsField])
        argsRow.orientation = .horizontal; argsRow.spacing = 8

        let stack = NSStackView(views: [autoLaunch, expand, sound, restore, fontRow, argsRow])
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
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggle(_:)))
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
    @objc private func argsChanged() { settings.defaultClaudeArgs = argsField.stringValue }
}
