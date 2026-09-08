import AppKit
import Observation
import SwiftUI

/// The status item and its popover.
///
/// `NSStatusItem` plus `NSPopover` rather than `MenuBarExtra`, because the panel must sit centred
/// under the icon and holds a picker and buttons. `MenuBarExtra` gives no control over where its
/// window lands; it hugs whichever screen edge it happens to be near.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: IssueStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void
    private var isDetached = false

    init(store: IssueStore,
         onOpenSettings: @escaping () -> Void,
         onRefresh: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.isDetached = UserDefaults.standard.bool(forKey: Keys.detached)

        configureButton()
        configurePopover()
        updateIcon()
        observeStore()

        // Reopen detached if that is how it was left.
        if isDetached { openDetachedWindow() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    private func configureButton() {
        // A stable autosave name, never the generic "Item-N" AppKit assigns. The visibility of a
        // status item is persisted per slot, and a generic slot can inherit a `false` left behind
        // by an unrelated build. Control Center's log showed exactly that: two tracked hosts, one
        // of them reporting clientRequestsVisibility false, and no icon on the bar.
        statusItem.autosaveName = "ticketbar.status.v1"
        // Not removable by command-dragging it off the bar, which is one documented way a bundle
        // id ends up on Control Center's blocked list.
        statusItem.behavior = []
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Jirabar")
    }

    /// The one panel, built the same way whether it is hosted in the popover or in the detached
    /// window, so the two can never drift apart.
    private func makeRootView() -> AnyView {
        AnyView(PopoverRootView(store: store,
                                onOpenSettings: { [weak self] in self?.openSettings() },
                                onRefresh: { [weak self] in self?.onRefresh() },
                                onQuit: { NSApp.terminate(nil) },
                                onToggleDetach: { [weak self] in self?.toggleDetach() },
                                isDetached: isDetached))
    }

    private func configurePopover() {
        let hosting = NSHostingController(rootView: makeRootView())
        // The panel grows with its content instead of being pinned to one guessed size.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    // MARK: - Showing

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        // Detached, the status item raises the window instead of opening a second copy of the
        // same panel underneath it.
        if isDetached {
            openDetachedWindow()
            return
        }
        popover.isShown ? close() : show()
    }

    // MARK: - Detaching

    func toggleDetach() {
        isDetached.toggle()
        UserDefaults.standard.set(isDetached, forKey: Keys.detached)

        if isDetached {
            close()
            openDetachedWindow()
        } else {
            DetachedWindow.shared.close()
        }
        // The popover keeps its own copy of the panel, so it has to be rebuilt with the new flag.
        configurePopover()
    }

    private func openDetachedWindow() {
        // Activate so the comment field gets the caret. The window is a titled NSWindow, which is
        // what lets it become key while the app stays `.accessory` and out of the Dock.
        WindowActivation.claim()
        DetachedWindow.shared.show(rootView: makeRootView()) { [weak self] in
            guard let self, self.isDetached else { return }
            // Closing the window is also a way of saying "put it back".
            self.isDetached = false
            UserDefaults.standard.set(false, forKey: Keys.detached)
            self.configurePopover()
        }
    }

    func show() {
        guard !isDetached, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover appears behind the frontmost app's windows when the status
        // item is clicked while another app is active.
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    /// Entry point for a notification click: open the popover already showing that issue.
    func openIssue(_ key: String) {
        store.selectedKey = key
        show()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(menuRefresh), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Settings...", action: #selector(menuSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jirabar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // The menu is attached only for this click. Leaving it attached would make every later
        // left click open the menu instead of the popover.
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { onRefresh() }

    @objc private func menuSettings() { openSettings() }

    private func openSettings() {
        close()
        onOpenSettings()
    }

    @objc private func applicationDidResignActive() {
        // Nothing to dismiss when detached: a window that vanished on focus loss would defeat the
        // entire point of tearing it off.
        guard !isDetached else { return }
        close()
    }

    // MARK: - Icon

    /// `withObservationTracking` fires once per change, so it re-arms itself. Without the re-arm
    /// the icon updates exactly one time and then never again.
    private func observeStore() {
        withObservationTracking {
            _ = store.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeStore()
            }
        }
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let defaults = UserDefaults.standard
        let issues = store.state.issues
        let image = StatusItemIcon.image(
            urgency: StatusItemIcon.Urgency.from(issues),
            monochrome: defaults.bool(forKey: Keys.monochromeIcon))
        button.image = image
        button.setAccessibilityLabel(accessibilityLabel())
        button.toolTip = accessibilityLabel()
    }

    private func accessibilityLabel() -> String {
        switch store.state {
        case .needsToken: return "Jirabar: no token yet"
        case .loading: return "Jirabar: loading"
        case .empty: return "Jirabar: no open issues"
        case .tokenRejected: return "Jirabar: token expired"
        case .unreachable: return "Jirabar: cannot reach the server"
        case .failed: return "Jirabar: error"
        case .issues:
            let count = store.badgeCount
            return count == 1 ? "Jirabar: 1 open issue" : "Jirabar: \(count) open issues"
        }
    }
}
