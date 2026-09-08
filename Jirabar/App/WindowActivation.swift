import AppKit

/// Keeps the app out of the Dock, permanently.
///
/// This used to flip `.accessory` to `.regular` while any real window was open, on the belief that
/// an accessory app cannot take key focus and so text fields in its windows refuse first
/// responder. That is not what was actually happening. The window that refused first responder was
/// an `NSPanel`, and a panel declines key status on its own terms: `.titled` is what decides
/// whether a window can become key, and `DetachedWindow` is a titled `NSWindow`. The policy flip
/// was never the thing making the comment field work; `NSApp.activate` was.
///
/// The Dock tile was the visible cost of that mistake. 2026-09-09 the user asked for the Dock icon
/// to be gone in every case, detached window included, so the policy is now `.accessory` for the
/// life of the process and focus is taken by activating instead.
///
/// If a text field ever refuses the caret again, the thing to check is whether its window is
/// `.titled` and whether `canBecomeKey` is true, not the activation policy.
@MainActor
enum WindowActivation {

    /// Bring the app forward so a window can take key focus and the caret blinks.
    ///
    /// `ignoringOtherApps` is needed: an accessory app is not in the Cmd+Tab list, so a polite
    /// activation request can be deferred until the user clicks something, which reads as a text
    /// field that will not accept typing.
    static func claim() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-asserts the accessory policy. Kept as a call so that anything setting `.regular` in
    /// future, directly or through a framework, is corrected the next time a window closes rather
    /// than leaving a Dock tile behind for the rest of the session.
    static func evaluate() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
