import AppKit
import SwiftUI

/// The popover, torn off into a window that stays put.
///
/// A popover is `.transient`: it closes the moment focus moves, which is right for a glance and
/// wrong for reading a long comment thread or typing a reply with the browser open beside it.
/// Detaching hosts the same view in a floating window instead.
///
/// A plain `NSWindow`, not an `NSPanel`: `WindowActivation` derives the activation policy from the
/// titled non-panel windows on screen, so a panel would leave the app `.accessory` and text fields
/// inside it would refuse first responder.
@MainActor
final class DetachedWindow: NSObject, NSWindowDelegate {
    static let shared = DetachedWindow()

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    func show(rootView: AnyView, onClose: @escaping () -> Void) {
        self.onClose = onClose

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Ticketbar"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Above other apps' windows, so it can sit beside a browser without being buried.
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Remembers where it was put, per Mac.
        window.setFrameAutosaveName("ticketbar.detached")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let callback = onClose
        onClose = nil
        DispatchQueue.main.async {
            callback?()
            WindowActivation.evaluate()
        }
    }
}
