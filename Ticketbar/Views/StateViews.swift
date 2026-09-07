import SwiftUI

/// The one layout every non-list state uses, so the failures look deliberate rather than like
/// four different accidents.
struct StatePlaceholder<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

/// No token yet. Onboarding, not a failure, so it is not red and does not apologise.
struct NeedsTokenView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "key",
                         tint: .accentColor,
                         title: "Connect your Jira account",
                         message: "Paste a Personal Access Token in Settings and Ticketbar will show the issues assigned to you.") {
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// 401 or 403. A PAT expires on a schedule the Jira admin sets, so this is a routine state with
/// a routine fix, not an error to be ashamed of. It must never be rendered as an empty list.
struct TokenRejectedView: View {
    let tokenPageURL: URL?
    let onOpenSettings: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "lock.trianglebadge.exclamationmark",
                         tint: .orange,
                         title: "Your token expired",
                         message: "Jira rejected the Personal Access Token. Create a new one and paste it into Settings.") {
            if let tokenPageURL {
                Link("Create a Token", destination: tokenPageURL)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Settings", action: onOpenSettings)
                .controlSize(.small)
        }
    }
}

/// Cannot reach the host. On an internal Jira this is the VPN nine times out of ten, so it says
/// so out loud instead of making the user guess.
struct UnreachableView: View {
    let host: String
    let reason: String
    let onRetry: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "wifi.exclamationmark",
                         tint: .orange,
                         title: "Cannot reach \(host)",
                         message: "\(reason) This host is internal, so check that you are on the corporate network or the VPN.") {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// The only state that means "nothing assigned to you". Reached from a successful, genuinely
/// empty search result, and from nowhere else.
struct EmptyIssuesView: View {
    let onRefresh: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "checkmark.circle",
                         tint: .green,
                         title: "Nothing assigned to you",
                         message: "No unresolved issues have your name on them right now.") {
            Button("Refresh", action: onRefresh)
                .controlSize(.small)
        }
    }
}

/// Anything that is not one of the above, shown with the server's own words rather than being
/// squeezed into a state it does not belong in.
struct GenericFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "exclamationmark.triangle",
                         tint: .red,
                         title: "Something went wrong",
                         message: message) {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading your issues")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
