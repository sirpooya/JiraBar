import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationService()
    private var store: IssueStore!
    private var poller: Poller!
    private var statusItemController: StatusItemController!

    /// The unit tests use the app as their TEST_HOST, so this delegate runs for them too. Without
    /// this guard every test run would raise a status item, start polling and open Settings.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        // First, always: UserDefaults.bool answers false for an absent key, so anything whose
        // default is not false has to be registered before anything reads it.
        Keys.registerDefaults()

        notifications.configure()

        let forced = QCHooks.forcedState()
        store = IssueStore(notifications: notifications, forcedState: forced)

        statusItemController = StatusItemController(
            store: store,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onRefresh: { [weak self] in self?.poller.refreshNow() })

        notifications.onOpenIssue = { [weak self] key in
            self?.statusItemController.openIssue(key)
        }

        poller = Poller(intervalProvider: { Keys.pollInterval() },
                        action: { [weak self] in
                            guard let self else { return false }
                            return await self.store.refresh()
                        })
        poller.start()

        installMainMenu()
        installEditingShortcuts()
        observeSleepAndWake()
        observeDefaults()

        // A forced state exists only so it can be photographed, so open the popover for it.
        if forced != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.statusItemController.show()
            }
        } else if !store.hasToken {
            showSettings()
        }
    }

    // MARK: - Main menu

    /// An accessory app shows no menu bar, and this one had no main menu at all. AppKit routes the
    /// standard editing shortcuts through the main menu, so with none there `Cmd+V` reached
    /// nothing: pasting into the comment composer or the token field did exactly nothing, and the
    /// text view's own `paste(_:)`, which is where a pasted screenshot is intercepted, was never
    /// called. Right-clicking for the contextual menu worked, because a text view builds that one
    /// itself, which is what made this look like an image-only problem.
    ///
    /// The menu is never seen. It exists so the shortcuts work.
    private func installMainMenu() {
        let main = NSMenu()

        // AppKit treats the first submenu as the application menu, so Edit has to come second to
        // land where the shortcuts expect it.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Jirabar",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // Written as bare selector names rather than #selector: these live on NSText, NSTextView
        // and the undo manager's responder, and naming a type here would only pick one of them.
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// Delivers the standard editing shortcuts to whatever has focus.
    ///
    /// The menu above is not enough on its own. AppKit dispatches these through `NSApp.mainMenu`,
    /// and this app's only scene is a `MenuBarExtra`, so SwiftUI owns that menu and replaces what
    /// the delegate installs. Nothing then handled `Cmd+V` at all: not in the comment box, not in
    /// the token field, for text as much as for a pasted screenshot.
    ///
    /// A local monitor sees the key before the window dispatches it, so it does not depend on the
    /// menu or on the responder chain agreeing. It only acts when the focused responder can
    /// actually perform the action, and otherwise hands the event straight back untouched.
    private func installEditingShortcuts() {
        editingShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift],
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let responder = event.window?.firstResponder
                      ?? NSApp.keyWindow?.firstResponder else { return event }

            let action: Selector?
            switch (flags, key) {
            case (.command, "v"): action = Selector(("paste:"))
            case (.command, "c"): action = Selector(("copy:"))
            case (.command, "x"): action = Selector(("cut:"))
            case (.command, "a"): action = Selector(("selectAll:"))
            case (.command, "z"): action = Selector(("undo:"))
            case ([.command, .shift], "z"): action = Selector(("redo:"))
            default: action = nil
            }

            guard let action else { return event }

            if responder.responds(to: action) {
                #if DEBUG
                FileHandle.standardError.write(Data("[keys] cmd+\(key) -> \(action) on \(type(of: responder))\n".utf8))
                #endif
                NSApp.sendAction(action, to: responder, from: nil)
                return nil
            }

            // Undo and redo live on the undo manager rather than on the responder itself.
            if let undo = responder.undoManager {
                if action == Selector(("undo:")), undo.canUndo { undo.undo(); return nil }
                if action == Selector(("redo:")), undo.canRedo { undo.redo(); return nil }
            }
            return event
        }
    }

    // MARK: - Sleep and wake

    /// Polling stops for the duration of the sleep and does exactly one refresh on wake, rather
    /// than firing every tick that was missed.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poller.pauseForSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poller.resumeFromWake() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poller.resumeFromWake() }
        }
    }

    /// The icon reacts to its two settings without needing a restart.
    /// The two defaults the menu bar icon is drawn from. Everything else the icon depends on,
    /// the badge count and the urgency colour, comes from the store through `observeStore`.
    private struct IconSettings: Equatable {
        let monochrome: Bool

        init(_ defaults: UserDefaults) {
            monochrome = defaults.bool(forKey: Keys.monochromeIcon)
        }
    }

    private var iconSettings: IconSettings?
    private var editingShortcutMonitor: Any?

    private func observeDefaults() {
        iconSettings = IconSettings(UserDefaults.standard)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.iconSettingsMayHaveChanged() }
        }
    }

    /// Two guards, both of which this crashed without.
    ///
    /// `didChangeNotification` fires for every key in the domain, not just the ones asked for,
    /// and AppKit itself writes to that domain: a window with a frame autosave name persists its
    /// frame as it lays out. So the values are compared first, and a write the icon does not
    /// depend on does no work at all.
    ///
    /// Then the update is deferred by a turn of the run loop, because the notification is posted
    /// synchronously from inside whatever wrote. Setting the status button's image from inside a
    /// window's layout pass marks the status bar window as needing another Update Constraints
    /// pass while it is already in one, and AppKit answers that with an NSGenericException:
    /// "more Update Constraints in Window passes than there are views in the window".
    private func iconSettingsMayHaveChanged() {
        let current = IconSettings(UserDefaults.standard)
        guard current != iconSettings else { return }
        iconSettings = current
        DispatchQueue.main.async { [weak self] in
            self?.statusItemController.updateIcon()
        }
    }

    // MARK: - Settings

    private func showSettings() {
        // Activate so the token field gets the caret. This does not add a Dock tile: the app
        // stays `.accessory` and only comes forward.
        WindowActivation.claim()
        SettingsWindow.shared.show(store: store,
                                   notifications: notifications,
                                   onRefresh: { [weak self] in self?.poller.refreshNow() })
    }

    // MARK: - Menu-bar app lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
