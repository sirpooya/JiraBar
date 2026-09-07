import SwiftUI

struct PopoverRootView: View {
    @Bindable var store: IssueStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    private static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            if let key = store.selectedKey, let issue = store.issue(for: key) {
                IssueDetailView(issue: issue, store: store) {
                    store.selectedKey = nil
                    store.actionError = nil
                }
            } else {
                header
                Divider().opacity(0.5)
                content
                Divider().opacity(0.5)
                footer
            }
        }
        .frame(width: Self.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.accountName ?? "Ticketbar")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if case .issues(let list) = store.state {
                Text("\(list.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            Spacer()

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

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            IssueListView(issues: issues, store: store)

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
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not updated yet")
            }
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                                     isBusy: store.busyKeys.contains(issue.key),
                                     onSelect: {
                                         store.actionError = nil
                                         store.selectedKey = issue.key
                                     },
                                     onDone: {
                                         Task { await store.markDone(issue.key) }
                                     })
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }
            // Tall enough for roughly five rows; longer lists scroll rather than growing a
            // popover past the bottom of the screen.
            .frame(maxHeight: 380)
        }
    }
}
