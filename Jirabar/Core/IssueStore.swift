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
    private(set) var state: ContentState = .loading {
        didSet {
            // Only a real result updates this. A failure or a genuinely empty column must not
            // shrink the placeholder the NEXT column switch draws, because the next column has
            // nothing to do with this one's outcome.
            if case .issues(let list) = state { lastIssueCount = list.count }
        }
    }

    /// The last row count actually shown. See the `didSet` above.
    private(set) var lastIssueCount = 0
    private(set) var accountName: String?
    /// The username from /myself, which is what author matching uses.
    private(set) var accountUsername: String?
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Keys with a transition in flight, so the row can show a spinner and refuse a second click.
    private(set) var busyKeys: Set<String> = []
    private(set) var transitionsByKey: [String: [JiraTransition]] = [:]
    private(set) var commentsByKey: [String: [JiraComment]] = [:]
    /// Keys whose comments are being fetched, so the detail view can say so rather than looking
    /// like an issue with no discussion on it.
    private(set) var loadingComments: Set<String> = []
    /// The composer's text. Shared so a pasted image can append its markup to whatever is typed.
    var commentDraft: String = ""
    /// Non-nil while an existing comment is being edited rather than a new one written.
    private(set) var editingCommentID: String?
    private(set) var isSubmittingComment = false
    private(set) var isUploadingImage = false
    /// Reactions per comment id. Absent means not loaded, or the endpoint is not available here.
    private(set) var reactionsByComment: [String: [JiraReaction]] = [:]
    /// Images referenced by rendered HTML, as `data:` URIs keyed by the `src` exactly as it
    /// appears in that HTML. Filled in the background; whatever has arrived is substituted the
    /// next time the thread renders, and the rest keep their original src.
    private(set) var inlinedImages: [String: String] = [:]
    private var loadingImages: Set<String> = []
    /// A screenshot inlined as base64 costs about a third more than the file. Past this the image
    /// is left as a broken link rather than putting a document of many megabytes into a web view.
    private static let maxInlineImageBytes = 8 * 1024 * 1024

    /// Avatar image bytes, keyed by the avatar URL. Held for the session: a board column is the
    /// same handful of people all day, and each image is a couple of kilobytes.
    private(set) var avatarData: [String: Data] = [:]
    private var loadingAvatars: Set<String> = []
    /// The comment whose reaction picker is open, if any.
    var pickingReactionFor: String?
    /// A failure from an action (moving an issue), which is separate from a failure to load.
    var actionError: String?
    /// The issue the detail view is showing, or nil for the list.
    var selectedKey: String? {
        didSet {
            guard selectedKey != oldValue else { return }
            commentDraft = ""
            editingCommentID = nil
        }
    }

    /// The board's columns, read from the server. Empty until the first successful load.
    private(set) var columns: [BoardColumn] = []

    /// The column being listed. Nil only before the columns have ever loaded.
    /// True only while `restoreCachedBoard()` is seeding the initial selection, so the observer
    /// below does not clear state that has just been set and does not fire a refresh the poller
    /// is about to make anyway.
    private var isRestoringScope = false

    var scope: BoardColumn? {
        didSet {
            guard !isRestoringScope, scope != oldValue else { return }
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
        self.accountUsername = defaults.string(forKey: Keys.accountUsername)
        if let forcedState {
            self.state = forcedState
            // A forced state never talks to the server, so the dropdown would otherwise be empty
            // and the board scope could not be photographed.
            self.columns = QCHooks.qcColumns
            self.commentsByKey = QCHooks.sampleComments
            self.transitionsByKey = QCHooks.sampleTransitions
            self.reactionsByComment = QCHooks.sampleReactions
        }
        restoreCachedBoard()
        if forcedState != nil { self.selectedKey = QCHooks.forcedSelection() }
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

    /// True when the popover is showing fixtures rather than anything from the server.
    var isShowingSampleData: Bool { forcedState != nil }

    /// The menu bar count: whatever the selected column holds.
    var badgeCount: Int { state.openCount }

    /// The count the HEADER shows, which is not always the menu bar's.
    ///
    /// While a column is loading this holds the number that was on screen a moment ago, so
    /// switching columns changes the value in place instead of taking the badge away and putting
    /// it back a fifth of a second later. Only `.loading` gets that grace: an empty column and
    /// every failure answer for themselves, so the rule that a stale badge on an expired token is
    /// a worse lie than no badge is untouched. `badgeCount` above, which is what the menu bar
    /// draws, is never softened this way.
    var displayCount: Int { state.isLoading ? lastIssueCount : state.openCount }

    /// Rows for the loading skeleton. The outgoing column's count is the only guess available for
    /// the incoming one. Clamped so a first launch still draws a panel and a very long column does
    /// not draw fifty placeholders nobody will see before the real rows arrive.
    var skeletonRowCount: Int { min(max(lastIssueCount, 4), 7) }

    // MARK: - Board

    /// Columns are cached so the dropdown is populated on the very first frame after launch,
    /// before any network call has come back.
    private func restoreCachedBoard() {
        isRestoringScope = true
        defer { isRestoringScope = false }

        if columns.isEmpty,
           let data = defaults.data(forKey: Keys.cachedColumns),
           let cached = try? JSONDecoder().decode([BoardColumn].self, from: data) {
            columns = cached
        }
        let stored = defaults.string(forKey: Keys.selectedScope) ?? ""
        scope = columns.first { $0.name == stored } ?? columns.first
    }

    /// Reads the board's columns from the server, two ways:
    ///   1. the pinned board id, which is the DDS board's own `rapidView` number,
    ///   2. discovery by project key, in case the board was rebuilt and renumbered.
    ///
    /// If neither answers, `columns` stays empty and the popover says the board could not be
    /// read. There is deliberately no hardcoded list to fall back on: one used to exist, built
    /// from an older board's workflow, and it silently showed nine plausible columns that had
    /// nothing to do with this board.
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
        // No fallback list. A guessed set of columns is indistinguishable from real board data
        // on screen, which is the same failure mode as showing an empty list for an expired token.
        guard !discovered.isEmpty else { return }

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
            state = .failed("Could not read the columns of board \(boardID) in \(projectKey). Check that you can open the board in a browser.")
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
            accountUsername = user.name
            defaults.set(user.displayName, forKey: Keys.accountDisplayName)
            defaults.set(user.name, forKey: Keys.accountUsername)
            return .success(user)
        } catch let error as JiraError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    func forgetAccount() {
        accountName = nil
        accountUsername = nil
        defaults.removeObject(forKey: Keys.accountDisplayName)
        defaults.removeObject(forKey: Keys.accountUsername)
        try? tokenStore.delete(for: baseURL)
        state = .needsToken
    }

    // MARK: - Transitions

    func loadTransitions(for key: String) async {
        guard forcedState == nil, let client else { return }
        // Deduplicated: hovering a row asks for these, and a pointer crossing a list asks often.
        guard transitionsByKey[key] == nil, !loadingTransitions.contains(key) else { return }
        loadingTransitions.insert(key)
        defer { loadingTransitions.remove(key) }
        if let list = try? await client.transitions(for: key) {
            transitionsByKey[key] = list
            #if DEBUG
            let offered = list
                .map { "\($0.name)->\($0.to?.name ?? "?")(\($0.to?.id ?? "no id"))" }
                .joined(separator: ", ")
            FileHandle.standardError.write(Data("[moves] \(key): \(offered)\n".utf8))
            #endif
        }
    }

    private var loadingTransitions: Set<String> = []

    /// Comments are a separate request, made only when a detail view opens. Folding them into
    /// the list search would make every poll fetch discussion for fifty issues nobody has opened.
    func loadComments(for key: String) async {
        guard forcedState == nil, let client else { return }
        guard commentsByKey[key] == nil, !loadingComments.contains(key) else { return }
        loadingComments.insert(key)
        defer { loadingComments.remove(key) }
        // A failure here is not worth a whole error state: the description is still readable, so
        // the section just stays empty.
        commentsByKey[key] = (try? await client.comments(for: key)) ?? []
        await loadReactions(for: key)
        // Last: the thread is already on screen by now, and the images fill in behind it.
        await loadImages(in: (commentsByKey[key] ?? []).map(\.html).joined())
    }

    // MARK: - Jira's own icons

    /// Icon bytes keyed by the URL Jira reported, for the icons that are not bundled.
    ///
    /// This instance serves its Task icon from `/secure/viewavatar?avatarId=10318`, a PNG chosen
    /// per instance rather than one of the named files under `/images/icons`. No bundled asset can
    /// match it, so it is fetched through the client like an avatar, with the same token and the
    /// same host guard.
    private(set) var iconData: [String: Data] = [:]
    private var loadingIcons: Set<String> = []

    func loadIcon(at url: String?) async {
        guard forcedState == nil, let client, let url, !url.isEmpty else { return }
        guard iconData[url] == nil, !loadingIcons.contains(url) else { return }
        guard let resolved = URL(string: url, relativeTo: baseURL) else { return }
        loadingIcons.insert(url)
        defer { loadingIcons.remove(url) }

        guard let data = try? await client.imageData(at: resolved) else {
            JiraIconAsset.reportMissing(url, name: "fetch failed")
            return
        }
        iconData[url] = data
    }

    func icon(for url: String?) -> Data? {
        url.flatMap { iconData[$0] }
    }

    // MARK: - Issue fields

    /// The side panel fields (components, labels, story points, affected versions), per issue.
    private(set) var fieldRowsByKey: [String: [IssueFieldRow]] = [:]
    private var loadingFieldRows: Set<String> = []

    /// Loaded when an issue is opened, never for the list. Silent on failure: the issue still
    /// reads without its side panel.
    func loadFieldRows(for key: String) async {
        guard forcedState == nil, let client else { return }
        guard fieldRowsByKey[key] == nil, !loadingFieldRows.contains(key) else { return }
        loadingFieldRows.insert(key)
        defer { loadingFieldRows.remove(key) }
        if let rows = try? await client.fieldRows(for: key) {
            fieldRowsByKey[key] = rows
        }
    }

    // MARK: - Images inside rendered HTML

    /// Fetches every image a block of server-rendered HTML points at, through the client, so the
    /// request carries the token. Silent per image: one that fails leaves the rest readable.
    func loadImages(in html: String) async {
        guard forcedState == nil, let client, let base = baseURL, !html.isEmpty else { return }
        for source in HTMLImages.sources(in: html) {
            guard inlinedImages[source] == nil, !loadingImages.contains(source) else { continue }
            guard let url = URL(string: source, relativeTo: base) else { continue }
            loadingImages.insert(source)
            defer { loadingImages.remove(source) }
            guard let data = try? await client.imageData(at: url),
                  data.count <= Self.maxInlineImageBytes else { continue }
            inlinedImages[source] = HTMLImages.dataURI(
                mime: HTMLImages.mimeType(forPath: url.path), data: data)
        }
    }

    /// Substitutes the images that have arrived so far.
    func inliningImages(in html: String) -> String {
        guard !inlinedImages.isEmpty else { return html }
        return HTMLImages.rewriting(html) { inlinedImages[$0] }
    }

    // MARK: - Avatars

    /// Fetches one assignee's avatar, once. Silent on failure: a missing image leaves the
    /// initials in place, which already answers whose issue it is.
    func loadAvatar(for user: JiraUser) async {
        guard forcedState == nil, let client, let url = user.avatarURL else { return }
        let key = url.absoluteString
        guard avatarData[key] == nil, !loadingAvatars.contains(key) else { return }
        loadingAvatars.insert(key)
        defer { loadingAvatars.remove(key) }
        if let data = try? await client.avatar(at: url) {
            avatarData[key] = data
        }
    }

    func avatar(for user: JiraUser) -> Data? {
        user.avatarURL.flatMap { avatarData[$0.absoluteString] }
    }

    // MARK: - Reactions

    /// Loads reactions for a whole thread. `/rest/internal/2` is Jira's own undocumented UI API,
    /// so a failure here is silent: the chips just do not appear, and the thread still reads.
    func loadReactions(for key: String) async {
        guard forcedState == nil, let client else { return }
        for comment in commentsByKey[key] ?? [] {
            if let found = try? await client.reactions(issueKey: key, commentID: comment.id) {
                reactionsByComment[comment.id] = found
            }
        }
    }

    /// Adds your reaction, or takes it back if it is already yours. Taking back your own reaction
    /// is not the comment-delete Jirabar refuses to have: it cannot touch anyone else's content.
    func toggleReaction(_ emojiId: String, commentID: String, on key: String) async {
        guard let client else { return }
        let existing = reactionsByComment[commentID]?.first { $0.emojiId == emojiId }
        let isMine = existing?.currentUserReacted == true

        do {
            if isMine {
                try await client.removeReaction(emojiId, issueKey: key, commentID: commentID)
            } else {
                try await client.addReaction(emojiId, issueKey: key, commentID: commentID)
            }
            if let refreshed = try? await client.reactions(issueKey: key, commentID: commentID) {
                reactionsByComment[commentID] = refreshed
                // Jira's internal API can answer 200 and still not record anything. Reading the
                // reactions back is the only way to know, and saying so beats a click that looks
                // like it worked and then quietly is not there.
                let stuck = refreshed.contains {
                    $0.emojiId == emojiId && ($0.currentUserReacted == true) != isMine
                }
                if !stuck {
                    actionError = "Jira accepted that but the reaction is not there when read back."
                }
            } else {
                actionError = "The reaction was sent, but Jira would not say what the reactions are now."
            }
        } catch let error as JiraError {
            actionError = Self.message(for: error)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Writing comments
    //
    // Add and edit only. There is no delete anywhere in this type, and there must never be one:
    // deleting a comment is done in the browser, where it takes more than one stray click in a
    // popover that opens under the cursor.

    /// Which comments this user may edit. Jira decides for real, but offering Edit on somebody
    /// else's comment only to have the server refuse it is a worse experience than not offering it.
    func editableCommentIDs(for key: String) -> Set<String> {
        let comments = commentsByKey[key] ?? []
        // Username first. Display name is only a fallback for a server that omits the username,
        // and it is unreliable: the same person reads as "Pouya Kamel" or "Pooya Kamel" depending
        // on who transliterated it.
        if let username = accountUsername, !username.isEmpty {
            return Set(comments.filter { $0.author?.name == username }.map(\.id))
        }
        guard let displayName = accountName else { return [] }
        return Set(comments.filter { $0.authorName == displayName }.map(\.id))
    }

    func beginCommentEdit(_ id: String, on key: String) {
        guard let comment = commentsByKey[key]?.first(where: { $0.id == id }) else { return }
        editingCommentID = id
        // The raw wiki markup, not the rendered HTML: that is what Jira expects back.
        commentDraft = comment.body ?? ""
        actionError = nil
    }

    func cancelCommentEdit() {
        editingCommentID = nil
        commentDraft = ""
    }

    func submitComment(on key: String) async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, !isSubmittingComment else { return }

        isSubmittingComment = true
        actionError = nil
        defer { isSubmittingComment = false }

        do {
            if let editing = editingCommentID {
                try await client.updateComment(id: editing, body: text, on: key)
            } else {
                try await client.addComment(text, to: key)
            }
            commentDraft = ""
            editingCommentID = nil
            // Re-read rather than splicing the new comment in: the server owns the rendered body,
            // the timestamps and the ordering.
            commentsByKey[key] = nil
            await loadComments(for: key)
        } catch let error as JiraError {
            actionError = Self.message(for: error)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Uploads a pasted screenshot and appends the wiki markup that shows it inline.
    func attachPastedImage(_ data: Data, to key: String) async {
        guard let client, !isUploadingImage else { return }
        isUploadingImage = true
        actionError = nil
        defer { isUploadingImage = false }

        let name = "ticketbar-\(Int(Date().timeIntervalSince1970)).png"
        do {
            let stored = try await client.attach(imageData: data, filename: name, to: key)
            // Jira renders `!file.png|thumbnail!` as an inline thumbnail of the attachment.
            let markup = "!\(stored)|thumbnail!"
            commentDraft += commentDraft.isEmpty ? markup : "\n\(markup)"
        } catch let error as JiraError {
            actionError = Self.message(for: error)
        } catch {
            actionError = error.localizedDescription
        }
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
            commentsByKey[key] = nil
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
