import SwiftUI

/// The status item, the popover and the settings window are all AppKit objects owned by
/// `AppDelegate`. SwiftUI still needs a scene to exist, so this declares one that presents
/// nothing: `isInserted` is bound to a constant false, so no second menu bar item appears.
@main
struct JirabarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var neverInserted = false

    var body: some Scene {
        MenuBarExtra("Jirabar", isInserted: $neverInserted) {
            EmptyView()
        }
    }
}
