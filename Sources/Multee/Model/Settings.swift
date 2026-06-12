import Foundation
import Combine

/// App settings, backed by `UserDefaults`. `@Published` so view controllers can `sink` and react;
/// each `didSet` persists. Not a SwiftUI type — Combine is independent of SwiftUI.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var autoLaunchClaude: Bool { didSet { d.set(autoLaunchClaude, forKey: K.autoLaunch) } }
    @Published var expandIgnored: Bool    { didSet { d.set(expandIgnored, forKey: K.expandIgnored) } }
    @Published var soundEnabled: Bool     { didSet { d.set(soundEnabled, forKey: K.sound) } }
    @Published var restoreOnLaunch: Bool  { didSet { d.set(restoreOnLaunch, forKey: K.restore) } }
    @Published var fontSize: Double       { didSet { d.set(fontSize, forKey: K.fontSize) } }
    @Published var defaultClaudeArgs: String { didSet { d.set(defaultClaudeArgs, forKey: K.defaultArgs) } }

    /// Alias used at call sites that read the default Claude args.
    var defaultArgs: String { defaultClaudeArgs }

    init() {
        d.register(defaults: [
            K.autoLaunch: true,
            K.expandIgnored: false,
            K.sound: true,
            K.restore: true,
            K.fontSize: 13.0,
            K.defaultArgs: "",
        ])
        // didSet does not fire for these initial assignments inside init.
        autoLaunchClaude  = d.bool(forKey: K.autoLaunch)
        expandIgnored     = d.bool(forKey: K.expandIgnored)
        soundEnabled      = d.bool(forKey: K.sound)
        restoreOnLaunch   = d.bool(forKey: K.restore)
        fontSize          = d.double(forKey: K.fontSize)
        defaultClaudeArgs = d.string(forKey: K.defaultArgs) ?? ""
    }

    /// Shared font size for terminal + editor, clamped to a readable range.
    func bumpFont(_ delta: Double) { fontSize = min(24, max(9, fontSize + delta)) }

    private enum K {
        static let autoLaunch    = "autoLaunchClaude"
        static let expandIgnored = "expandIgnored"
        static let sound         = "soundEnabled"
        static let restore       = "restoreOnLaunch"
        static let fontSize      = "fontSize"
        static let defaultArgs   = "defaultClaudeArgs"
    }
}
