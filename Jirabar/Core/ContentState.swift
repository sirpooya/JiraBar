import Foundation

/// What the popover is showing. The three failure states are separate cases with separate views
/// and separate actions, and there is no transition from any of them to `.empty`.
///
/// This enum is the enforcement mechanism for the rule in CLAUDE.md: an error can never be
/// rendered as "no issues". If a new failure appears, it gets a case here, not a silent fallthrough.
enum ContentState: Equatable {
    /// No token yet. Onboarding, not a failure.
    case needsToken
    /// First load, nothing to show yet. Later refreshes keep the previous issues on screen.
    case loading
    /// At least one issue. Never used for zero.
    case issues([JiraIssue])
    /// The search genuinely returned nothing. The only case that shows the empty state.
    case empty
    /// 401 or 403. Offers the token page.
    case tokenRejected
    /// Cannot reach the host. Offers a retry, and says the VPN out loud.
    case unreachable(String)
    /// Anything else, shown with its own message rather than pretending to be one of the above.
    case failed(String)

    /// True while a column is waiting for its first result. The panel keys the skeleton and the
    /// cross fade to the rows off this and nothing else, so an ordinary refresh, which replaces
    /// the same rows with newer ones, animates nothing.
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var issues: [JiraIssue] {
        if case .issues(let list) = self { return list }
        return []
    }

    /// The badge count. Every non-issue state counts zero, including the failures: a stale badge
    /// on an expired token is a worse lie than no badge.
    var openCount: Int { issues.count }

    static func from(_ issues: [JiraIssue]) -> ContentState {
        issues.isEmpty ? .empty : .issues(issues)
    }

    static func from(_ error: JiraError) -> ContentState {
        switch error {
        case .notConfigured:
            return .needsToken
        case .tokenRejected:
            return .tokenRejected
        case .hostUnreachable(let reason):
            return .unreachable(reason)
        case .tlsFailure(let reason):
            return .failed(reason + " The server's certificate was not accepted.")
        case .badRequest(let message):
            return .failed(message)
        case .notFound(let message):
            return .failed(message)
        case .serverError(let code):
            return .failed("Jira answered \(code). The server is having a problem, not this Mac.")
        case .decodingFailed(let message):
            return .failed(message)
        case .unexpected(let message):
            return .failed(message)
        }
    }

    /// Whether the poller should back off. Unreachable means stop hammering; a rejected token
    /// means stop entirely until the user fixes it.
    var isHealthy: Bool {
        switch self {
        case .issues, .empty, .loading: return true
        case .needsToken, .tokenRejected, .unreachable, .failed: return false
        }
    }
}
