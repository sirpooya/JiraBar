import AppKit
import SwiftUI

/// An `NSWindow` this app owns, not SwiftUI's `Settings` scene.
///
/// The `Settings` scene is the app's only presentable scene in a menu-bar app, and macOS will
/// open it by itself at launch. Owning the window also keeps it out of the SwiftUI tree that is
/// built before the status item exists.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(store: IssueStore, notifications: NotificationService, onRefresh: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store,
                                                                 notifications: notifications,
                                                                 onRefresh: onRefresh))
        // Empty on purpose: with `.preferredContentSize` AppKit re-measures the ScrollView
        // mid-layout and aborts.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Jirabar Settings"
        // Not resizable: the panes are laid out for one width.
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Opens to be read, not typed into.
        window.makeFirstResponder(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Hand the Dock tile back: the app is an accessory again once no real window is open.
        DispatchQueue.main.async { WindowActivation.evaluate() }
    }
}
