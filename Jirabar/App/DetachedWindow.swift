import AppKit
import SwiftUI

/// The popover, torn off into a window that stays put.
///
/// A popover is `.transient`: it closes the moment focus moves, which is right for a glance and
/// wrong for reading a long comment thread or typing a reply with the browser open beside it.
/// Detaching hosts the same view in a floating window instead.
///
/// A plain `NSWindow`, not an `NSPanel`, and this is what keeps the app out of the Dock. `.titled`
/// is what makes a window able to become key, so this window takes the caret while the app stays
/// `.accessory`. An `NSPanel` declines key status on its own terms, which is what text fields
/// refusing first responder was really about; see `WindowActivation`.
@MainActor
final class DetachedWindow: NSObject, NSWindowDelegate {
    static let shared = DetachedWindow()

    /// Matches the panel's own minimum width in `PopoverRootView`, read from there rather than
    /// restated, because a window that can be dragged narrower than the panel lays out at clips
    /// the panel instead of reflowing it.
    private static var width: CGFloat { PopoverRootView.minimumWidth }

    /// What a freshly torn-off window opens at, which is the popover's width and not the floor:
    /// detaching should hand you the panel you were already reading, not the narrowest one.
    private static let defaultWidth: CGFloat = 380
    private static let minHeight: CGFloat = 260

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
        window.title = "Jirabar"
        // Resizable, because nothing sizes it to its content any more: the height is the user's.
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        // `width` is the floor, not the ceiling: the panel fills this window now, so dragging it
        // wider gives the comment thread more room instead of adding empty margin. A saved frame
        // wider than the old fixed width restores intact rather than being clamped back.
        window.contentMinSize = NSSize(width: Self.width, height: Self.minHeight)
        window.contentMaxSize = NSSize(width: 1200, height: 2000)
        window.setContentSize(NSSize(width: Self.defaultWidth, height: 520))
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Above other apps' windows, so it can sit beside a browser without being buried.
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Remembers where it was put, per Mac.
        window.setFrameAutosaveName("ticketbar.detached")
        // Restoring an autosaved frame does not consult the minimum, so a frame saved by a build
        // that had no minimum comes back too narrow and clips the panel. Widen it on the way in.
        clampToMinimum(window)
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func close() {
        window?.close()
    }

    /// The panel does not reflow below `width` points, it clips, so the window must not go there.
    ///
    /// `contentMinSize` alone did not hold it: with `sizingOptions` empty the content imposes no
    /// constraints of its own, and the drag went straight past the minimum. This is the hook AppKit
    /// asks before every resize, so there is nowhere for it to slip through.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let floor = Self.minimumFrameSize(for: sender)
        return NSSize(width: max(frameSize.width, floor.width),
                      height: max(frameSize.height, floor.height))
    }

    private func clampToMinimum(_ window: NSWindow) {
        let floor = Self.minimumFrameSize(for: window)
        guard window.frame.width < floor.width || window.frame.height < floor.height else { return }
        var frame = window.frame
        // Grown from the top-left, which is where the title bar is: the window stays where the
        // user put it rather than sliding up the screen.
        frame.origin.y -= max(0, floor.height - frame.height)
        frame.size.width = max(frame.width, floor.width)
        frame.size.height = max(frame.height, floor.height)
        window.setFrame(frame, display: false)
    }

    /// The content minimum expressed as a frame, so the title bar is counted.
    private static func minimumFrameSize(for window: NSWindow) -> NSSize {
        let content = NSRect(origin: .zero, size: NSSize(width: width, height: minHeight))
        return window.frameRect(forContentRect: content).size
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
