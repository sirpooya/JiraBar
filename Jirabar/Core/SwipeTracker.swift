import CoreGraphics

enum SwipeDirection {
    case left
    case right
}

/// Accumulates a trackpad swipe across the scroll events it arrives as, and says which way it went
/// once it is over.
///
/// It exists because the obvious version does not work. A swipe is a run of `.scrollWheel` events
/// with a phase, and the `.began` and `.ended` events carry **zero deltas**: they are markers, not
/// movement. Testing each event for "is this more sideways than vertical" therefore rejects the
/// `.ended` event, `0 > 0` being false, and the gesture never completes. The direction has to be
/// judged from the whole gesture's travel, once, at the end.
struct SwipeTracker {
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0

    mutating func began() {
        travelX = 0
        travelY = 0
    }

    mutating func moved(deltaX: CGFloat, deltaY: CGFloat) {
        travelX += deltaX
        travelY += deltaY
    }

    /// The direction this swipe counts as, or nil when it was too small or mostly vertical.
    /// Resets either way, so the next swipe starts clean even if this one did nothing.
    mutating func ended(threshold: CGFloat) -> SwipeDirection? {
        let x = travelX
        let y = travelY
        travelX = 0
        travelY = 0

        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x > 0 ? .right : .left
    }

    /// For a mouse wheel or any device that reports no phases at all: one decisive push, judged
    /// on its own.
    static func direction(ofUnphasedDeltaX deltaX: CGFloat,
                          deltaY: CGFloat,
                          threshold: CGFloat) -> SwipeDirection? {
        guard abs(deltaX) > threshold, abs(deltaX) > abs(deltaY) else { return nil }
        return deltaX > 0 ? .right : .left
    }
}
