import AppKit
import QuartzCore

/// Shared motion vocabulary for the whole app. One place for durations + curves, and a single
/// Reduce-Motion gate so every animation degrades to instant when the system (or user) asks.
///
/// Prefer animating layer/compositing properties (opacity, transform, position, backgroundColor) —
/// they're GPU-composited and cost no per-frame CPU redraw. Don't drive Auto Layout or text relayout
/// per frame except where AppKit gives us no other handle (the bottom-dock divider, via `drive`).
enum Motion {
    /// Standard short transition (panels, fades, slides).
    static let quick: TimeInterval = 0.20
    /// Snappy micro-interaction (hover, press, state dots).
    static let micro: TimeInterval = 0.12

    /// System Reduce-Motion accessibility setting. When true, animations collapse to instant.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    static var easeIn: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
    static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }

    /// Run an NSAnimationContext group with our defaults (implicit animation on, ease-out).
    /// Under Reduce Motion the body still runs, just with zero duration so changes apply instantly
    /// through the same code path.
    static func animate(_ duration: TimeInterval = quick,
                        timing: CAMediaTimingFunction? = nil,
                        _ body: @escaping (NSAnimationContext) -> Void,
                        completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : duration
            ctx.timingFunction = timing ?? easeOut
            ctx.allowsImplicitAnimation = true
            body(ctx)
        }, completionHandler: completion)
    }

    /// Entrance for a centered overlay (dimming scrim + a content box): the scrim fades its dim in and
    /// the box scales up from 0.96 — the standard macOS popover/sheet feel. Layer-backed, GPU-composited.
    /// Model values are untouched (the box stays identity / opacity 1), so it settles correctly. No-op
    /// under Reduce Motion (the overlay simply appears).
    static func presentOverlay(scrim: NSView, box: NSView, duration: TimeInterval = quick) {
        scrim.wantsLayer = true; box.wantsLayer = true
        guard !reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = duration; fade.timingFunction = easeOut
        scrim.layer?.add(fade, forKey: "motion.overlay")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96; scale.toValue = 1
        scale.duration = duration; scale.timingFunction = easeOut
        box.layer?.add(scale, forKey: "motion.overlay")
    }

    /// Exit for a centered overlay: reverse of `presentOverlay` (scrim dim fades out, box scales down to
    /// 0.96), then `completion` runs — typically `scrim.removeFromSuperview()`. Held at the end state so
    /// there's no flash before removal; the scrim's opacity is restored for the next present. Under Reduce
    /// Motion it removes instantly via `completion`.
    static func dismissOverlay(scrim: NSView, box: NSView, duration: TimeInterval = 0.15,
                               completion: @escaping () -> Void) {
        scrim.wantsLayer = true; box.wantsLayer = true
        guard !reduceMotion else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            scrim.layer?.removeAnimation(forKey: "motion.overlay")
            box.layer?.removeAnimation(forKey: "motion.overlay")
            scrim.layer?.opacity = 1
            completion()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.duration = duration; fade.timingFunction = easeIn
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        scrim.layer?.add(fade, forKey: "motion.overlay")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 0.96
        scale.duration = duration; scale.timingFunction = easeIn
        scale.fillMode = .forwards; scale.isRemovedOnCompletion = false
        box.layer?.add(scale, forKey: "motion.overlay")
        CATransaction.commit()
    }

    /// Tactile press feedback: scale a control toward `pressed` (0.92) while the mouse is down and spring
    /// back to 1 on release. Uses an *explicit* `transform.scale` animation (layer-backed AppKit views
    /// suppress implicit CA animations) from the current presented scale, so taps and holds both read.
    /// The backing-layer anchorPoint is centered (0.5, 0.5), so it scales in place. No-op under Reduce Motion.
    static func press(_ view: NSView, _ pressed: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let to: Double = pressed ? 0.92 : 1
        // Reduce Motion: never shrink, and reset to identity (covers RM toggled on mid-press).
        guard !reduceMotion else { layer.setValue(1, forKeyPath: "transform.scale"); return }
        // Read as Double — NSNumber doesn't reliably bridge to CGFloat via `as?`, which would drop the
        // current scale and make the spring-back jump instead of animate.
        let from = (layer.presentation()?.value(forKeyPath: "transform.scale") as? Double)
            ?? (layer.value(forKeyPath: "transform.scale") as? Double) ?? 1
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = pressed ? 0.06 : 0.13
        anim.timingFunction = easeOut
        layer.setValue(to, forKeyPath: "transform.scale")   // model value, so it holds while pressed
        layer.add(anim, forKey: "motion.press")
    }

    /// Crossfade a layer's `backgroundColor` to a new value (e.g. a hover highlight). Animates from the
    /// currently *presented* colour so rapid hover in/out stays smooth, and sets the model value so it
    /// settles correctly. Instant under Reduce Motion.
    static func crossfadeBackground(_ layer: CALayer?, to color: CGColor?, duration: TimeInterval = micro) {
        guard let layer else { return }
        guard !reduceMotion else { layer.backgroundColor = color; return }
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        anim.toValue = color
        anim.duration = duration
        anim.timingFunction = easeOut
        layer.backgroundColor = color
        layer.add(anim, forKey: "motion.bg")
    }

    /// Fade a view in from transparent (e.g. a swapped-in panel). No-op under Reduce Motion.
    static func fadeIn(_ view: NSView, duration: TimeInterval = quick) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1
        a.duration = duration; a.timingFunction = easeOut
        layer.add(a, forKey: "motion.fadeIn")
    }

    /// Entrance for a freshly-inserted item (tab chip, list row): fade + a slight scale-up from 0.85.
    /// The model is untouched (settles at identity / opaque). No-op under Reduce Motion.
    static func popIn(_ view: NSView, duration: TimeInterval = quick) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85; scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration; group.timingFunction = easeOut
        layer.add(group, forKey: "motion.popIn")
    }

    /// GPU-composited vertical slide of a layer-backed view's content (`transform.translation.y`),
    /// without touching its frame — so no Auto Layout / text reflow happens per frame. The model
    /// value is left untouched (identity); `hold` keeps the presentation pinned at `to` after the
    /// animation (for slide-outs that are immediately removed). No-ops under Reduce Motion.
    static func slideY(_ view: NSView, from: CGFloat, to: CGFloat,
                       duration: TimeInterval = quick, timing: CAMediaTimingFunction? = nil,
                       hold: Bool = false, completion: (() -> Void)? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduceMotion else { completion?(); return }
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = timing ?? easeOut
        if hold { a.fillMode = .forwards; a.isRemovedOnCompletion = false }
        if let completion {
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)
            layer.add(a, forKey: "motion.slideY")
            CATransaction.commit()
        } else {
            layer.add(a, forKey: "motion.slideY")
        }
    }

    /// Eased per-frame interpolation from `from`→`to`, calling `step` each tick. The escape hatch for
    /// things AppKit's animator can't express reliably — notably `NSSplitView.setPosition`. Use ONLY where
    /// the per-frame work is cheap: panes of plain AppKit views are fine, but NEVER a split pane holding a
    /// terminal (it reflows/SIGWINCHes every frame — that's why the bottom dock uses `slideY` instead; D28).
    /// Returns the timer so a caller can cancel; jumps to `to` under Reduce Motion.
    @discardableResult
    static func drive(_ duration: TimeInterval = quick, from: Double, to: Double,
                      step: @escaping (Double) -> Void, done: @escaping () -> Void = {}) -> Timer? {
        if reduceMotion || duration <= 0 { step(to); done(); return nil }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = 1 - pow(1 - p, 3)   // cubic ease-out
            step(from + (to - from) * eased)
            if p >= 1 { t.invalidate(); done() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
