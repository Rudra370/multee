import AppKit

/// Tiny wrapper around the general pasteboard (used by the file-tree and tab context menus).
enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
