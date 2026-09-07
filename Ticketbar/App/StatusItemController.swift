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

    init(store: IssueStore,
         onOpenSettings: @escaping () -> Void,
         onRefresh: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        updateIcon()
        observeStore()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Ticketbar")
    }

    private func configurePopover() {
        let hosting = NSHostingController(rootView: PopoverRootView(store: store,
                                                                    onOpenSettings: { [weak self] in
                                                                        self?.openSettings()
                                                                    },
                                                                    onRefresh: { [weak self] in
                                                                        self?.onRefresh()
                                                                    },
                                                                    onQuit: { NSApp.terminate(nil) }))
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
        popover.isShown ? close() : show()
    }

    func show() {
        guard let button = statusItem.button else { return }
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
        menu.addItem(withTitle: "Quit Ticketbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
            count: store.state.openCount,
            urgency: StatusItemIcon.Urgency.from(issues),
            monochrome: defaults.bool(forKey: Keys.monochromeIcon),
            showCount: defaults.bool(forKey: Keys.showBadgeCount))
        button.image = image
        button.setAccessibilityLabel(accessibilityLabel())
        button.toolTip = accessibilityLabel()
    }

    private func accessibilityLabel() -> String {
        switch store.state {
        case .needsToken: return "Ticketbar: no token yet"
        case .loading: return "Ticketbar: loading"
        case .empty: return "Ticketbar: no open issues"
        case .tokenRejected: return "Ticketbar: token expired"
        case .unreachable: return "Ticketbar: cannot reach the server"
        case .failed: return "Ticketbar: error"
        case .issues(let list):
            return list.count == 1 ? "Ticketbar: 1 open issue" : "Ticketbar: \(list.count) open issues"
        }
    }
}
