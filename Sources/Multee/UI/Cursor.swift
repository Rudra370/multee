import AppKit

// Reliable pointing-hand cursor via a `.cursorUpdate` tracking area + `cursorUpdate(with:)` (the
// documented approach — more dependable than cursor rects, which AppKit doesn't always re-establish).
// `.inVisibleRect` keeps the area sized to the view automatically.

private func installPointerTracking(_ view: NSView) {
    guard view.window != nil else { return }
    if view.trackingAreas.contains(where: { $0.owner === view && $0.options.contains(.cursorUpdate) }) { return }
    view.addTrackingArea(NSTrackingArea(rect: .zero,
                                        options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect],
                                        owner: view, userInfo: nil))
}

/// NSButton that shows the pointing-hand cursor on hover.
class PointerButton: NSButton {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installPointerTracking(self) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Clickable container view (rows / chips) that shows the pointing-hand cursor over its bounds.
class PointerView: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installPointerTracking(self) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// NSSegmentedControl (e.g. Files/Changes, Unified/Split) with a pointing-hand cursor.
class PointerSegmentedControl: NSSegmentedControl {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installPointerTracking(self) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
