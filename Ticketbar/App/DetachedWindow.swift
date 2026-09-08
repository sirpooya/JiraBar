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

    /// Matches the panel's own fixed width in `PopoverRootView`.
    private static let width: CGFloat = 380

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
        // Deliberately not `.preferredContentSize`, which crashed the app on every launch it was
        // left detached in. With it the window resized itself to whatever the SwiftUI content
        // currently preferred, and this content changes height as it loads: the rendered
        // description and the comment thread each report their real height once laid out, and the
        // composer grows with the draft. Each change resized the window from inside AppKit's
        // layout pass, the resize made NSHostingView invalidate and mark constraints dirty again,
        // and AppKit aborts that with NSGenericException ("more Update Constraints in Window
        // passes than there are views in the window"). The window owns its size now and the
        // content scrolls inside it, which is what a window you tore off to read a long thread in
        // wants anyway.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Ticketbar"
        // Resizable, because nothing sizes it to its content any more: the height is the user's.
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        // 380 is the floor, not the ceiling: the panel fills this window now, so dragging it
        // wider gives the comment thread more room instead of adding empty margin. A saved frame
        // wider than the old fixed width restores intact rather than being clamped back.
        window.contentMinSize = NSSize(width: Self.width, height: 260)
        window.contentMaxSize = NSSize(width: 1200, height: 2000)
        window.setContentSize(NSSize(width: Self.width, height: 520))
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
