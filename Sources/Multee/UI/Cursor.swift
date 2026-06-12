import AppKit

/// NSButton that shows the pointing-hand cursor on hover. AppKit buttons default to the arrow; this
/// adds the web-style affordance the app wants on every clickable control.
class PointerButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Container view that shows the pointing-hand cursor over its whole bounds (for clickable rows /
/// chips whose body is the click target).
class PointerView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
