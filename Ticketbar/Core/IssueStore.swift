import Foundation
import Observation

/// The one piece of state the whole app reads: which board column is on screen, what is in it,
/// and what is in flight.
///
/// Everything that could turn a failure into "no issues" happens here, so it is all in one file
/// and easy to audit: `refresh()` writes `ContentState.from(issues:)` only on a successful
/// response, and `ContentState.from(error:)` on every failure.
@MainActor
@Observable
final class IssueStore {
    private(set) var state: ContentState = .loading
    private(set) var accountName: String?
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Keys with a transition in flight, so the row can show a spinner and refuse a second click.
    private(set) var busyKeys: Set<String> = []
    private(set) var transitionsByKey: [String: [JiraTransition]] = [:]
    /// A failure from an action (moving an issue), which is separate from a failure to load.
    var actionError: String?
    /// The issue the detail view is showing, or nil for the list.
    var selectedKey: String?

    /// The board's columns, read from the server. Empty until the first successful load.
    private(set) var columns: [BoardColumn] = []

    /// The column being listed. Nil only before the columns have ever loaded.
    var scope: BoardColumn? {
        didSet {
            guard scope != oldValue else { return }
            defaults.set(scope?.name ?? "", forKey: Keys.selectedScope)
            selectedKey = nil
            actionError = nil
            state = .loading
            Task { await refresh() }
        }
    }

    let tokenStore: TokenStore
    private let defaults: UserDefaults
    private let notifications: NotificationService
    private let session: URLSession
    /// One seen-issue set per column. Shared state would make every column switch a storm.
    private var seenByColumn: [String: SeenIssues] = [:]
    /// Set once QC forces a state, which then wins over anything the network says.
    private let forcedState: ContentState?

    init(defaults: UserDefaults = .standard,
         tokenStore: TokenStore = TokenStore(),
         notifications: NotificationService,
         session: URLSession = JiraClient.makeSession(),
         forcedState: ContentState? = nil) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.notifications = notifications
        self.session = session
        self.forcedState = forcedState
        self.accountName = defaults.string(forKey: Keys.accountDisplayName)
        if let forcedState {
            self.state = forcedState
            // A forced state never talks to the server, so the dropdown would otherwise be empty
            // and the board scope could not be photographed.
            self.columns = BoardColumn.fallback
        }
        restoreCachedBoard()
    }

    // MARK: - Configuration

    var baseURL: URL? {
        guard let text = defaults.string(forKey: Keys.baseURL),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    var hasToken: Bool { tokenStore.hasToken(for: baseURL) }

    var projectKey: String {
        let key = defaults.string(forKey: Keys.boardProjectKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? Keys.defaultProjectKey : key
    }

    var boardID: Int {
        let stored = defaults.integer(forKey: Keys.boardID)
        return stored > 0 ? stored : Keys.defaultBoardID
    }

    /// Built fresh each call so a token repaired in Settings takes effect immediately, and a
    /// changed base URL cannot be served by a stale client.
    var client: JiraClient? {
        guard let baseURL else { return nil }
        let store = tokenStore
        return JiraClient(baseURL: baseURL,
                          tokenProvider: { store.token(for: baseURL) },
                          session: session)
    }

    var tokenPageURL: URL? { client?.tokenPageURL }

    func browseURL(for key: String) -> URL? { client?.browseURL(for: key) }

    func issue(for key: String) -> JiraIssue? {
        state.issues.first { $0.key == key }
    }

    /// The menu bar count: whatever the selected column holds.
    var badgeCount: Int { state.openCount }

    // MARK: - Board

    /// Columns are cached so the dropdown is populated on the very first frame after launch,
    /// before any network call has come back.
    private func restoreCachedBoard() {
        if columns.isEmpty,
           let data = defaults.data(forKey: Keys.cachedColumns),
           let cached = try? JSONDecoder().decode([BoardColumn].self, from: data) {
            columns = cached
        }
        let stored = defaults.string(forKey: Keys.selectedScope) ?? ""
        scope = columns.first { $0.name == stored } ?? columns.first
    }

    /// Reads the board's columns, in three steps, each a fallback for the one before:
    ///   1. the pinned board id, which is the DDS board's own `rapidView` number,
    ///   2. discovery by project key, in case the board was rebuilt and renumbered,
    ///   3. the workflow statuses recorded in CLAUDE.md, for an instance that has the Agile API
    ///      switched off and answers 404 rather than saying so.
    func loadBoardColumns() async {
        guard forcedState == nil, let client else { return }
        var discovered: [BoardColumn] = []

        if let configuration = try? await client.boardConfiguration(id: boardID) {
            discovered = configuration.columns
        }
        if discovered.isEmpty,
           let boards = try? await client.boards(projectKey: projectKey), let board = boards.first,
           let configuration = try? await client.boardConfiguration(id: board.id) {
            discovered = configuration.columns
        }
        if discovered.isEmpty { discovered = BoardColumn.fallback }

        columns = discovered
        if let data = try? JSONEncoder().encode(discovered) {
            defaults.set(data, forKey: Keys.cachedColumns)
        }
        // A column that has gone away must not stay selected, or the list would query statuses
        // that no longer exist and come back empty for a reason the user cannot see.
        let wanted = scope?.name ?? defaults.string(forKey: Keys.selectedScope) ?? ""
        scope = discovered.first { $0.name == wanted } ?? discovered.first
    }

    // MARK: - Loading

    /// Returns true when the server answered. The poller uses that to decide whether to back off.
    @discardableResult
    func refresh() async -> Bool {
        if let forcedState {
            state = forcedState
            lastRefresh = Date()
            return forcedState.isHealthy
        }
        guard hasToken else {
            state = .needsToken
            return false
        }
        guard let client else {
            state = .failed("The base URL in Settings is not a valid address.")
            return false
        }
        if columns.isEmpty { await loadBoardColumns() }
        guard let column = scope else {
            state = .failed("No columns could be read from the board.")
            return false
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let issues = try await client.search(jql: column.jql(projectKey: projectKey))
            state = .from(issues)
            lastRefresh = Date()
            handleNewIssues(in: issues, for: column)
            return true
        } catch let error as JiraError {
            // Never fall through to an empty list. Every failure gets its own state.
            state = .from(error)
            return false
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private func seenIssues(for column: BoardColumn) -> SeenIssues {
        if let existing = seenByColumn[column.seenNamespace] { return existing }
        let created = SeenIssues(namespace: column.seenNamespace, defaults: defaults)
        seenByColumn[column.seenNamespace] = created
        return created
    }

    /// The seed is its own step, run before any diff can happen, so whatever is already in a
    /// column the first time it is opened never notifies.
    private func handleNewIssues(in issues: [JiraIssue], for column: BoardColumn) {
        let seen = seenIssues(for: column)
        let keys = issues.map(\.key)
        guard seen.isSeeded else {
            seen.seed(with: keys)
            return
        }
        guard defaults.bool(forKey: Keys.notifyOnNewIssue) else {
            seen.markSeen(keys)
            return
        }
        let freshKeys = Set(seen.unseen(among: keys))
        guard !freshKeys.isEmpty else { return }
        notifications.notify(newIssues: issues.filter { freshKeys.contains($0.key) },
                             columnName: column.name)
        seen.markSeen(keys)
    }

    // MARK: - Account

    /// Called by the Settings Test button. Records the display name so the popover footer can
    /// show who the token belongs to.
    func verifyToken(baseURL: URL, token: String) async -> Result<JiraUser, JiraError> {
        let probe = JiraClient(baseURL: baseURL, tokenProvider: { token }, session: session)
        do {
            let user = try await probe.myself()
            accountName = user.displayName
            defaults.set(user.displayName, forKey: Keys.accountDisplayName)
            return .success(user)
        } catch let error as JiraError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    func forgetAccount() {
        accountName = nil
        defaults.removeObject(forKey: Keys.accountDisplayName)
        try? tokenStore.delete(for: baseURL)
        state = .needsToken
    }

    // MARK: - Transitions

    func loadTransitions(for key: String) async {
        guard forcedState == nil, let client else { return }
        guard transitionsByKey[key] == nil else { return }
        if let list = try? await client.transitions(for: key) {
            transitionsByKey[key] = list
        }
    }

    /// Moves an issue to whichever transition lands in Jira's `done` category.
    func markDone(_ key: String) async {
        if transitionsByKey[key] == nil { await loadTransitions(for: key) }
        guard let done = transitionsByKey[key]?.first(where: { $0.landsInDone }) else {
            actionError = "This issue has no transition to Done from \(issue(for: key)?.statusName ?? "its current status")."
            return
        }
        await apply(done, to: key)
    }

    func apply(_ transition: JiraTransition, to key: String) async {
        guard let client, !busyKeys.contains(key) else { return }

        // A workflow that demands a resolution or a comment cannot be driven from one button, and
        // finding that out from a 400 after the click is worse than saying so before it.
        let blocking = transition.blockingFieldNames
        guard blocking.isEmpty else {
            actionError = "\(transition.name) needs \(blocking.joined(separator: ", ")) filled in. Open the issue in the browser to finish it."
            return
        }

        busyKeys.insert(key)
        actionError = nil
        defer { busyKeys.remove(key) }

        do {
            try await client.applyTransition(id: transition.id, to: key)
            transitionsByKey[key] = nil
            if selectedKey == key { selectedKey = nil }
            // Reload rather than guessing: the issue may leave the column, or may not, and only
            // the server knows which.
            await refresh()
        } catch let error as JiraError {
            actionError = Self.message(for: error)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private static func message(for error: JiraError) -> String {
        switch error {
        case .tokenRejected: return "Your token was rejected. Open Settings to paste a new one."
        case .hostUnreachable(let reason): return reason + " Check the VPN."
        case .badRequest(let message), .notFound(let message), .decodingFailed(let message),
             .unexpected(let message), .tlsFailure(let message):
            return message
        case .serverError(let code): return "Jira answered \(code)."
        case .notConfigured: return "No token stored yet."
        }
    }
}
