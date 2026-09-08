import AppKit
import SwiftUI

struct PopoverRootView: View {
    @Bindable var store: IssueStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    /// Tears the popover off into a floating window, or puts it back.
    let onToggleDetach: () -> Void
    let isDetached: Bool

    private static let width: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the next column change should travel. Set before the change, so the list leaves
    /// in the direction the swipe went rather than always the same way.
    @State private var columnGoesForward = true
    @State private var columnSwipeMonitor: Any?
    @State private var columnSwipe = SwipeTracker()

    /// The strip across the top the column swipe is read in, covering the header row.
    private static let headerStripHeight: CGFloat = 56
    private static let columnSwipeThreshold: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if let key = store.selectedKey, let issue = store.issue(for: key) {
                IssueDetailView(issue: issue, store: store, fillsHeight: isDetached) {
                    store.selectedKey = nil
                    store.actionError = nil
                }
                // Opening an issue pushes it in from the trailing edge and takes the list out to
                // the leading one, so the two read as one place you moved through rather than as
                // a swap. Going back runs it the other way, which is the same direction the swipe
                // across the header goes.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                if store.isShowingSampleData { sampleDataBanner }
                header
                Divider().opacity(0.5)
                content
                    .id(store.scope?.id ?? "no-column")
                    .transition(.asymmetric(
                        insertion: .move(edge: columnGoesForward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: columnGoesForward ? .leading : .trailing)
                            .combined(with: .opacity)))
                Divider().opacity(0.5)
                footer
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        // Clipped, or the view sliding out is drawn beyond the panel while it goes.
        .clipped()
        // Short on purpose. In the popover the panel is sized to its content, so this animates the
        // popover's own size as well, and a long one would leave the window stretching visibly.
        // Off entirely when the system asks for less motion.
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: store.selectedKey)
        // In the popover the size is the content's: a popover has no frame of its own to fill,
        // so the width is pinned and the scroll areas are capped.
        //
        // In the detached window it is the other way round. The window's size is the user's, and
        // the panel fills it in both directions, with 380 as the floor. Pinned to 380 the panel
        // sat in a window dragged out to 572 with a wide empty margin beside it, and navigating
        // between the list and an issue changed nothing about the window, only what was stranded
        // inside it.
        .frame(minWidth: Self.width,
               maxWidth: isDetached ? .infinity : Self.width,
               maxHeight: isDetached ? .infinity : nil)
        .onAppear { installColumnSwipe() }
        .onDisappear { removeColumnSwipe() }
    }

    /// Shown only under `--qc-state=...`. Loud on purpose: fixture issues look exactly like real
    /// ones, and a build accidentally left running with the flag reads as a genuine board.
    private var sampleDataBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("SAMPLE DATA")
                .font(.system(size: 10, weight: .bold))
            Text("not your Jira. Launched with --qc-state.")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.yellow)
    }

    // MARK: - Header

    /// A ZStack, not an HStack: the dropdown is centred on the popover, so it must not be pushed
    /// around by however wide the count pill or the buttons happen to be.
    private var header: some View {
        ZStack {
            scopePicker

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }

                Button(action: onToggleDetach) {
                    // A pin, because it says what detaching is for rather than what it makes: the
                    // panel stays put instead of closing the moment focus moves. Filled while it
                    // is pinned. Not the picture-in-picture pair this started as, which borrowed a
                    // video metaphor for a window.
                    Image(systemName: isDetached ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(isDetached ? "Put it back in the menu bar" : "Detach into a floating window")
                .accessibilityLabel(isDetached ? "Return to the menu bar" : "Detach into a window")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The board's columns, and nothing else. They come from the server, so a board the team
    /// rearranges needs no change here.
    // MARK: - Swiping between columns

    /// A two-finger swipe across the header steps through the board's columns, left for the next
    /// one and right for the previous, which is the same direction sense as the swipe back inside
    /// an issue. The ends hold instead of wrapping.
    ///
    /// A local scroll monitor for the same reason as the swipe back: a trackpad swipe is a scroll
    /// event with precise deltas and a phase, and no SwiftUI gesture reports it.
    private func installColumnSwipe() {
        guard columnSwipeMonitor == nil else { return }
        columnSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleColumnSwipe(event) ? nil : event
        }
    }

    private func removeColumnSwipe() {
        if let columnSwipeMonitor { NSEvent.removeMonitor(columnSwipeMonitor) }
        columnSwipeMonitor = nil
    }

    /// Never consumes the event: the list underneath still has to scroll normally, and a swipe
    /// only ever adds an action once it has finished.
    private func handleColumnSwipe(_ event: NSEvent) -> Bool {
        // Only over the list. An issue is open on top of this, and a swipe there means go back.
        guard store.selectedKey == nil, store.columns.count > 1 else { return false }
        guard let contentHeight = event.window?.contentView?.bounds.height,
              event.locationInWindow.y > contentHeight - Self.headerStripHeight else { return false }

        if event.phase.contains(.began) {
            columnSwipe.began()
        } else if event.phase.contains(.changed) {
            columnSwipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if let direction = columnSwipe.ended(threshold: Self.columnSwipeThreshold) {
                step(forward: direction == .left)
            }
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            let direction = SwipeTracker.direction(ofUnphasedDeltaX: event.scrollingDeltaX,
                                                   deltaY: event.scrollingDeltaY,
                                                   threshold: Self.columnSwipeThreshold)
            if let direction { step(forward: direction == .left) }
        }
        return false
    }

    private func step(forward: Bool) {
        guard let next = ColumnPaging.column(after: store.scope,
                                             in: store.columns,
                                             forward: forward) else { return }
        select(next)
    }

    /// Changes column with the list sliding the way you went. Used by the swipe and by the
    /// dropdown, so picking "Done" from the menu travels the same direction as swiping to it.
    private func select(_ column: BoardColumn) {
        if let from = store.scope.flatMap({ store.columns.firstIndex(of: $0) }),
           let to = store.columns.firstIndex(of: column) {
            columnGoesForward = to > from
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            store.scope = column
        }
    }

    /// The count sits beside the menu rather than inside its label: a `Menu` in the borderless
    /// style renders only the first view of a composed label, so a badge and a name together left
    /// the name invisible. Outside the menu it can be a real badge again, and it still reads in
    /// front of the column name and before the chevron.
    private var scopePicker: some View {
        HStack(spacing: 5) {
            if store.badgeCount > 0 {
                Text("\(store.badgeCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help("\(store.badgeCount) issues in this column")
            }
            columnMenu
        }
    }

    private var columnMenu: some View {
        Menu {
            ForEach(store.columns) { column in
                Button {
                    select(column)
                } label: {
                    Label(column.name, systemImage: store.scope == column ? "checkmark" : "")
                }
            }
        } label: {
            // No hand-drawn chevron here. `.menuIndicator(.hidden)` does not take on the
            // borderless menu style, so a custom one just ends up as a second arrow in the wrong
            // place; the system indicator is left to do its own job.
            // The count sits with the column name rather than in a badge of its own off to the
            // left: it is a fact about this column, and two separate things in the header read as
            // two unrelated things.
            // One `Text`, not a stack of them. A `Menu` in the borderless style renders only the
            // first view of a composed label, so the count drew and the column name vanished.
            Text(store.scope?.name ?? "Loading board...")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.columns.isEmpty)
        .accessibilityLabel("Showing \(store.scope?.name ?? "no column yet"), \(store.badgeCount) issues. Choose a board column.")
    }

    // MARK: - Content

    /// One switch, one case per state. There is no `default`, so a new state cannot quietly
    /// inherit somebody else's view, and no branch here can draw an empty list for a failure.
    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .needsToken:
            NeedsTokenView(onOpenSettings: onOpenSettings)

        case .loading:
            LoadingView()

        case .issues(let issues):
            IssueListView(issues: issues, store: store, fillsHeight: isDetached)

        case .empty:
            EmptyIssuesView(onRefresh: onRefresh)

        case .tokenRejected:
            TokenRejectedView(tokenPageURL: store.tokenPageURL, onOpenSettings: onOpenSettings)

        case .unreachable(let reason):
            UnreachableView(host: store.baseURL?.host ?? "the server",
                            reason: reason,
                            onRetry: onRefresh)

        case .failed(let message):
            GenericFailureView(message: message, onRetry: onRefresh)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let name = store.accountName {
                Text(name).lineLimit(1)
                Text("·")
            }
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not updated yet")
            }
            Spacer(minLength: 4)
            if !isDetached {
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct IssueListView: View {
    let issues: [JiraIssue]
    @Bindable var store: IssueStore
    var fillsHeight = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.actionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.10))
            }

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(issues) { issue in
                        IssueRowView(issue: issue,
                                     store: store,
                                     showsStatus: store.scope?.gathersMultipleStatuses ?? false,
                                     onSelect: {
                                         store.actionError = nil
                                         store.selectedKey = issue.key
                                     })
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }
            // Roughly five rows in the popover, which cannot be allowed to grow past the bottom
            // of the screen. In the detached window the list takes the height the window has.
            .frame(maxHeight: fillsHeight ? .infinity : 380)
        }
    }
}
