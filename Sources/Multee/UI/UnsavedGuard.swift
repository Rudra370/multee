import AppKit

/// Confirms before discarding unsaved editor edits when a tab, a folder (session), or the app closes.
/// Lives apart from the views: the model holds the dirty flag (`Tab.dirty`), and the editor layer
/// registers `saveTab` so the guard can persist a tab without reaching into view controllers itself.
/// Dialogs are app-modal (`runModal`) so the control flow stays synchronous — important for the quit
/// path (`applicationShouldTerminate` must answer right away).
enum UnsavedGuard {
    /// Set by `CenterViewController`: write a tab's editor to disk by id (returns `true` if it isn't an
    /// editor or the write succeeded; `false` if a blank "New File" tab's save panel was cancelled).
    static var saveTab: ((String) -> Bool)?

    enum Response { case save, dontSave, cancel }

    /// Dev-harness only: when non-nil, close confirmations skip the modal and use this answer (so the
    /// close/quit wiring is testable without clicking a dialog). Never set in release — `DebugHarness`
    /// is gated on `Bundle.main.isDev`.
    static var debugResponse: Response?

    /// One dirty tab → Save / Cancel / Don't Save. Returns `true` if the caller may close it.
    static func confirmClose(_ tab: Tab) -> Bool {
        guard tab.dirty else { return true }
        return apply(debugResponse ?? ask(
            message: "Do you want to save the changes you made to “\(tab.title)”?",
            info: "Your changes will be lost if you don’t save them.",
            saveTitle: "Save & Close", dontSaveTitle: "Don’t Save & Close"), to: [tab])
    }

    /// Dirty tabs closing together (folder/app) → Save All / Cancel / Discard. Returns `true` to proceed.
    static func confirmCloseMany(_ dirty: [Tab], verb: String) -> Bool {
        guard !dirty.isEmpty else { return true }
        if dirty.count == 1 { return confirmClose(dirty[0]) }
        return apply(debugResponse ?? ask(
            message: "You have unsaved changes in \(dirty.count) files.",
            info: "Do you want to save them before \(verb)?",
            saveTitle: "Save All", dontSaveTitle: "Discard"), to: dirty)
    }

    /// Run the three-button alert and map the click to a `Response`.
    private static func ask(message: String, info: String, saveTitle: String, dontSaveTitle: String) -> Response {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: saveTitle)                         // default / Return
        alert.addButton(withTitle: "Cancel")                          // Escape (NSAlert maps it)
        alert.addButton(withTitle: dontSaveTitle)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default:                      return .cancel
        }
    }

    /// Carry out the chosen response; returns whether the caller should proceed to close.
    private static func apply(_ r: Response, to tabs: [Tab]) -> Bool {
        switch r {
        case .save:
            // Save every tab (don't short-circuit, so all that can be saved are), but if any blank-tab
            // save panel was cancelled, abort the close so its text isn't lost.
            let saved = tabs.map { saveTab?($0.id) ?? true }
            return !saved.contains(false)
        case .dontSave: return true     // discard edits
        case .cancel:   return false
        }
    }
}
