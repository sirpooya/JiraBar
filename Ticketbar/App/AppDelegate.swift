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
    private func observeDefaults() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItemController.updateIcon() }
        }
    }

    // MARK: - Settings

    private func showSettings() {
        // An accessory app cannot take key focus, so the token field would refuse first responder.
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
