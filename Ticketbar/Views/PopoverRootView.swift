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

    var body: some View {
        VStack(spacing: 0) {
            if let key = store.selectedKey, let issue = store.issue(for: key) {
                IssueDetailView(issue: issue, store: store, fillsHeight: isDetached) {
                    store.selectedKey = nil
                    store.actionError = nil
                }
            } else {
                if store.isShowingSampleData { sampleDataBanner }
                header
                Divider().opacity(0.5)
                content
                Divider().opacity(0.5)
                footer
            }
        }
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
                if store.badgeCount > 0 {
                    Text("\(store.badgeCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .help("\(store.badgeCount) issues in this column")
                }

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
                    // Not the picture-in-picture pair, which borrows a video metaphor for a
                    // window. Each icon names its own destination: a window to tear off into,
                    // the menu bar to go back to.
                    Image(systemName: isDetached ? "menubar.rectangle" : "macwindow")
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
    private var scopePicker: some View {
        Menu {
            ForEach(store.columns) { column in
                Button {
                    store.scope = column
                } label: {
                    Label(column.name, systemImage: store.scope == column ? "checkmark" : "")
                }
            }
        } label: {
            // No hand-drawn chevron here. `.menuIndicator(.hidden)` does not take on the
            // borderless menu style, so a custom one just ends up as a second arrow in the wrong
            // place; the system indicator is left to do its own job.
            Text(store.scope?.name ?? "Loading board...")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.columns.isEmpty)
        .accessibilityLabel("Showing \(store.scope?.name ?? "no column yet"). Choose a board column.")
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
