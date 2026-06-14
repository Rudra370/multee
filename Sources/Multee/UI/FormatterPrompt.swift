import AppKit

/// The user-facing side of formatting: the just-in-time "formatter isn't installed" prompt (with a
/// one-click install that runs in a Terminal tab), plus small notices for "no formatter for this file"
/// and formatter errors. App-modal (`runModal`) for simple synchronous flow.
enum FormatterPrompt {
    /// Open Settings → Formatters (registered by AppDelegate).
    static var openManager: (() -> Void)?

    /// The chosen formatter isn't installed → explain, offer one-click install (Terminal) or copy.
    static func notInstalled(_ spec: FormatterSpec) {
        let command = spec.installCommand
        let alert = NSAlert()
        alert.messageText = "Formatting needs \(spec.name), which isn’t installed."
        alert.informativeText = "Multee will run this in a new Terminal tab so you can watch it:\n\n\(command)"
        alert.addButton(withTitle: "Install in Terminal")   // default
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Manage Formatters…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            FormatterInstall.run?(command)              // opens a Terminal tab running the command
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .alertThirdButtonReturn:
            openManager?()
        default:
            break
        }
    }

    /// The formatter for this file is installed but turned off in Settings → Formatters.
    static func disabled(_ spec: FormatterSpec) {
        let alert = NSAlert()
        alert.messageText = "Formatting with \(spec.name) is turned off."
        alert.informativeText = "Enable it in Settings → Formatters to format this file."
        alert.addButton(withTitle: "Manage Formatters…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openManager?() }
    }

    /// No formatter is configured for this file type.
    static func noFormatter(ext: String) {
        let alert = NSAlert()
        alert.messageText = ext.isEmpty ? "No formatter for this file type."
                                        : "No formatter for .\(ext) files."
        alert.informativeText = "Multee doesn’t have a formatter mapped to this file type yet."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The formatter ran but failed (syntax error, bad config, …) — show its output, change nothing.
    static func failed(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t format this file."
        alert.informativeText = String(message.prefix(2000))
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
