import AppKit

/// An `LSUIElement` app runs `.accessory`, and an accessory app cannot take key focus, so text
/// fields in its windows refuse first responder. Every real window claims `.regular` while it is
/// open and hands it back when the last one closes.
///
/// The policy is derived from the window list, never from a counter: a counter drifts the first
/// time a window closes by a path nobody remembered to instrument.
@MainActor
enum WindowActivation {

    static func claim() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func evaluate() {
        NSApp.setActivationPolicy(hasOpenWindow ? .regular : .accessory)
    }

    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && window.className != "NSStatusBarWindow"
        }
    }
}
