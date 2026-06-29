import AppKit

// Custom cursors (the pointing hand over clickable things). AppKit has TWO cursor mechanisms and they
// don't compose: cursor **rects** (`resetCursorRects`/`addCursorRect`, owned by the window) and the
// **tracking-area `cursorUpdate`** callback. A window effectively runs in cursor-rect mode once you
// interact with a cursor-rect view (every NSButton — incl. ours — registers cursor rects). In that
// mode it STOPS delivering `cursorUpdate` to tracking-area-only views, so their cursor goes stale
// (e.g. the file tree's pointing hand reverted to arrow after a toolbar button click, recovering only
// on a relayout or focus change). **Rule: every custom-cursor view must register cursor rects
// (`resetCursorRects`).** Views with changing content (the outline's rows) ALSO keep a `cursorUpdate`
// for live hit-testing and must `invalidateCursorRects` when content changes (reload/collapse) so the
// rects stay current. We use `.cursorUpdate` + `.inVisibleRect` tracking here, but cursor rects are
// the load-bearing half — don't drop them. See the "Two cursor mechanisms" gotcha in CLAUDE.md.

private func installPointerTracking(_ view: NSView) {
    guard view.window != nil else { return }
    if view.trackingAreas.contains(where: { $0.owner === view && $0.options.contains(.cursorUpdate) }) { return }
    view.addTrackingArea(NSTrackingArea(rect: .zero,
                                        options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect],
                                        owner: view, userInfo: nil))
}

/// NSButton that shows the pointing-hand cursor on hover, with a subtle tactile press (scale-down while
/// held, spring back on release). `super.mouseDown` runs the click's modal tracking loop, so we bracket
/// it: scale down before, scale up after it returns on mouse-up. Subclasses (HoverIconButton/ChipButton/
/// ClosureButton) don't override mouseDown, so they inherit the press.
class PointerButton: NSButton {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installPointerTracking(self) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        Motion.press(self, true)
        super.mouseDown(with: event)
        Motion.press(self, false)
    }
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

/// NSOutlineView (the file tree) that shows the pointing-hand cursor over its rows and the plain
/// arrow over empty space below them — matching every other clickable element in the app.
class PointerOutlineView: NSOutlineView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installPointerTracking(self) }
    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (row(at: point) >= 0 ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    // The toolbar buttons (PointerButton) use cursor *rects*; after one is clicked the window is in
    // cursor-rect mode and the tracking-area `cursorUpdate` above goes stale over the rows until a
    // relayout/focus change. Participating in cursor rects too keeps the pointing hand correct in that
    // state. Only the actual rows get the hand (empty space below stays arrow). Kept current by
    // invalidating on every reloadData and after collapse-all.
    override func resetCursorRects() {
        let visible = rows(in: visibleRect)
        guard visible.length > 0 else { return }
        for i in visible.location..<NSMaxRange(visible) { addCursorRect(rect(ofRow: i), cursor: .pointingHand) }
    }
    override func reloadData() { super.reloadData(); window?.invalidateCursorRects(for: self) }
}
