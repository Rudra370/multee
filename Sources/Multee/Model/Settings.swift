import Foundation
import Combine

/// App settings, backed by `UserDefaults`. `@Published` so view controllers can `sink` and react;
/// each `didSet` persists. Not a SwiftUI type — Combine is independent of SwiftUI.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var autoLaunchClaude: Bool { didSet { d.set(autoLaunchClaude, forKey: K.autoLaunch) } }
    @Published var expandIgnored: Bool    { didSet { d.set(expandIgnored, forKey: K.expandIgnored) } }
    @Published var soundEnabled: Bool     { didSet { d.set(soundEnabled, forKey: K.sound) } }
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: K.notifications) } }
    @Published var restoreOnLaunch: Bool  { didSet { d.set(restoreOnLaunch, forKey: K.restore) } }
    @Published var fontSize: Double       { didSet { d.set(fontSize, forKey: K.fontSize) } }
    @Published var defaultClaudeArgs: String { didSet { d.set(defaultClaudeArgs, forKey: K.defaultArgs) } }
    @Published var showResourceMonitor: Bool { didSet { d.set(showResourceMonitor, forKey: K.resourceMonitor) } }
    /// Formatter ids the user has turned off (empty = all enabled).
    @Published var disabledFormatters: Set<String> { didSet { d.set(Array(disabledFormatters), forKey: K.disabledFormatters) } }
    @Published var formatOnSave: Bool { didSet { d.set(formatOnSave, forKey: K.formatOnSave) } }
    /// Find-bar toggles, remembered across files + launches (like VS Code).
    @Published var findMatchCase: Bool { didSet { d.set(findMatchCase, forKey: K.findMatchCase) } }
    @Published var findWholeWord: Bool { didSet { d.set(findWholeWord, forKey: K.findWholeWord) } }
    @Published var findRegex: Bool     { didSet { d.set(findRegex, forKey: K.findRegex) } }

    /// Alias used at call sites that read the default Claude args.
    var defaultArgs: String { defaultClaudeArgs }

    init() {
        d.register(defaults: [
            K.autoLaunch: true,
            K.expandIgnored: false,
            K.sound: true,
            K.notifications: true,
            K.restore: true,
            K.fontSize: 13.0,
            K.defaultArgs: "",
            K.resourceMonitor: false,
            K.formatOnSave: false,
        ])
        // didSet does not fire for these initial assignments inside init.
        autoLaunchClaude  = d.bool(forKey: K.autoLaunch)
        expandIgnored     = d.bool(forKey: K.expandIgnored)
        soundEnabled      = d.bool(forKey: K.sound)
        notificationsEnabled = d.bool(forKey: K.notifications)
        restoreOnLaunch   = d.bool(forKey: K.restore)
        fontSize          = d.double(forKey: K.fontSize)
        defaultClaudeArgs = d.string(forKey: K.defaultArgs) ?? ""
        showResourceMonitor = d.bool(forKey: K.resourceMonitor)
        disabledFormatters = Set((d.array(forKey: K.disabledFormatters) as? [String]) ?? [])
        formatOnSave = d.bool(forKey: K.formatOnSave)
        findMatchCase = d.bool(forKey: K.findMatchCase)
        findWholeWord = d.bool(forKey: K.findWholeWord)
        findRegex = d.bool(forKey: K.findRegex)
    }

    /// Shared font size for terminal + editor, clamped to a readable range.
    func bumpFont(_ delta: Double) { fontSize = min(24, max(9, fontSize + delta)) }

    func formatterEnabled(_ id: String) -> Bool { !disabledFormatters.contains(id) }
    func setFormatter(_ id: String, enabled: Bool) {
        if enabled { disabledFormatters.remove(id) } else { disabledFormatters.insert(id) }
    }

    private enum K {
        static let autoLaunch    = "autoLaunchClaude"
        static let expandIgnored = "expandIgnored"
        static let sound         = "soundEnabled"
        static let notifications = "notificationsEnabled"
        static let restore       = "restoreOnLaunch"
        static let fontSize      = "fontSize"
        static let defaultArgs   = "defaultClaudeArgs"
        static let resourceMonitor = "showResourceMonitor"
        static let disabledFormatters = "disabledFormatters"
        static let formatOnSave = "formatOnSave"
        static let findMatchCase = "findMatchCase"
        static let findWholeWord = "findWholeWord"
        static let findRegex = "findRegex"
    }
}
