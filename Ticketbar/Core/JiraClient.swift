import Foundation

/// Every network call the app makes. Nothing else in the app touches URLSession.
///
/// Server/DC, `/rest/api/2`, bearer PAT. See CLAUDE.md for why there is no other auth path.
struct JiraClient {
    let baseURL: URL
    /// Read at call time, never captured, so a token repaired in Settings takes effect on the
    /// next poll without rebuilding the client.
    let tokenProvider: () -> String?
    let session: URLSession

    init(baseURL: URL, tokenProvider: @escaping () -> String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// `waitsForConnectivity` stays false on purpose. With it on, a request made off the VPN hangs
    /// until the timeout instead of failing, and the popover sits on a spinner rather than saying
    /// the host is unreachable.
    static func makeSession(timeout: TimeInterval = 15) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: - Calls

    /// Validates the token and returns who the server thinks you are.
    func myself() async throws -> JiraUser {
        try await get("/rest/api/2/myself", query: [:], as: JiraUser.self)
    }

    /// Any JQL. One field list and one expand for every search, so a scope added later cannot
    /// forget `renderedFields` and end up with no description in the detail view.
    func search(jql: String, maxResults: Int = 50) async throws -> [JiraIssue] {
        let query: [String: String] = [
            "jql": jql,
            "fields": "summary,description,status,priority,issuetype,updated,duedate,parent,assignee,customfield_10411",
            "expand": "renderedFields",
            "maxResults": String(maxResults),
        ]
        let response = try await get("/rest/api/2/search", query: query, as: JiraSearchResponse.self)
        return response.issues
    }

    /// One user's avatar, as image bytes.
    ///
    /// Fetched here rather than by the view, because on a private instance the avatar sits behind
    /// the same bearer token as every other call and an unauthenticated load returns a login page
    /// or a stranger's default image. The host is checked first: the token goes to the Jira host
    /// and nowhere else, whatever URL the server happens to hand back.
    func avatar(at url: URL) async throws -> Data {
        try await imageData(at: url)
    }

    /// Any image on the Jira host: an avatar, or an image attached to a comment or a description.
    ///
    /// The host is checked first, so the token goes to the Jira host and nowhere else whatever URL
    /// the server put in the rendered HTML.
    func imageData(at url: URL) async throws -> Data {
        guard let host = url.host, host == baseURL.host else {
            throw JiraError.unexpected("That image is not on the Jira host.")
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw JiraError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    // MARK: - Agile board

    /// The boards belonging to a project. Server/DC serves the Agile API from its own path.
    func boards(projectKey: String) async throws -> [AgileBoard] {
        let response = try await get("/rest/agile/1.0/board",
                                     query: ["projectKeyOrId": projectKey, "maxResults": "50"],
                                     as: AgileBoardsResponse.self)
        return response.values
    }

    func boardConfiguration(id: Int) async throws -> BoardConfiguration {
        try await get("/rest/agile/1.0/board/\(id)/configuration", query: [:], as: BoardConfiguration.self)
    }

    /// The transitions this issue can take right now, for this user. Always read before writing:
    /// transition ids differ per workflow scheme, so hardcoding one is a bug waiting for the next
    /// project.
    func transitions(for issueKey: String) async throws -> [JiraTransition] {
        let response = try await get("/rest/api/2/issue/\(issueKey)/transitions",
                                     query: ["expand": "transitions.fields"],
                                     as: JiraTransitionsResponse.self)
        return response.transitions
    }

    /// Moves an issue. `fields.status` is not writable; this is the only way.
    func applyTransition(id: String, to issueKey: String) async throws {
        let body: [String: Any] = ["transition": ["id": id]]
        try await post("/rest/api/2/issue/\(issueKey)/transitions", body: body)
    }

    /// An issue's comments, newest first, rendered by the server.
    func comments(for issueKey: String, maxResults: Int = 30) async throws -> [JiraComment] {
        let response = try await get("/rest/api/2/issue/\(issueKey)/comment",
                                     // "-created" is newest first, which is the order the web UI
                                     // shows and therefore the order these are read in.
                                     query: ["expand": "renderedBody",
                                             "orderBy": "-created",
                                             "maxResults": String(maxResults)],
                                     as: JiraCommentsResponse.self)
        return response.comments
    }

    func addComment(_ text: String, to issueKey: String) async throws {
        try await post("/rest/api/2/issue/\(issueKey)/comment", body: ["body": text])
    }

    /// Edits an existing comment. Jira allows this with edit-own or edit-all permission; the
    /// server decides, and a refusal comes back as 403 and is shown as such.
    func updateComment(id: String, body: String, on issueKey: String) async throws {
        try await put("/rest/api/2/issue/\(issueKey)/comment/\(id)", body: ["body": body])
    }

    // MARK: - Reactions
    //
    // `/rest/internal/2` is Jira Server/DC's own UI API and is undocumented. Every call here is
    // treated as optional: a failure means the reaction row does not appear, never an error state.

    func reactions(issueKey: String, commentID: String) async throws -> [JiraReaction] {
        let response = try await get("/rest/internal/2/issue/\(issueKey)/comment/\(commentID)/reactions",
                                     query: [:], as: JiraReactionsResponse.self)
        return response.reactions ?? []
    }

    func addReaction(_ emojiId: String, issueKey: String, commentID: String) async throws {
        try await attempt(Self.reactionCalls(adding: true,
                                             emojiId: emojiId,
                                             issueKey: issueKey,
                                             commentID: commentID))
    }

    /// Removes *your own* reaction. This is not the comment-delete that Ticketbar refuses to have:
    /// it takes back something you added, and cannot touch anyone else's comment or reaction.
    func removeReaction(_ emojiId: String, issueKey: String, commentID: String) async throws {
        try await attempt(Self.reactionCalls(adding: false,
                                             emojiId: emojiId,
                                             issueKey: issueKey,
                                             commentID: commentID))
    }

    /// One way of asking this instance to record a reaction.
    private struct ReactionCall {
        let method: String
        let path: String
        let query: [String: String]
    }

    /// The shapes Jira Server/DC has used for comment reactions, most likely first.
    ///
    /// `/rest/internal/2` is Jira's own UI API. It is undocumented, it changed between versions,
    /// and the single shape this used to send returned 404 on works.digikala.com. Rather than
    /// guess again, each shape is tried until one is accepted. A 404 records nothing, so the
    /// attempts that miss cannot leave anything behind on somebody's board, and at most one of
    /// them can succeed.
    private static func reactionCalls(adding: Bool,
                                      emojiId: String,
                                      issueKey: String,
                                      commentID: String) -> [ReactionCall] {
        let comment = "/rest/internal/2/issue/\(issueKey)/comment/\(commentID)"
        let write = adding ? "PUT" : "DELETE"
        return [
            ReactionCall(method: write, path: "\(comment)/reaction", query: ["emojiId": emojiId]),
            ReactionCall(method: adding ? "POST" : "DELETE",
                         path: "\(comment)/reactions",
                         query: ["emojiId": emojiId]),
            ReactionCall(method: write, path: "\(comment)/reaction/\(emojiId)", query: [:]),
            ReactionCall(method: adding ? "POST" : "DELETE",
                         path: "/rest/internal/2/comment/\(commentID)/reactions",
                         query: ["emojiId": emojiId]),
        ]
    }

    /// Sends each call until one is not rejected, and throws what the last one said if none are.
    private func attempt(_ calls: [ReactionCall]) async throws {
        var lastError: Error = JiraError.unexpected("This Jira did not accept the reaction.")
        for call in calls {
            do {
                let request = try makeRequest(path: call.path,
                                              query: call.query,
                                              method: call.method,
                                              body: nil)
                _ = try await send(request)
                return
            } catch let error as JiraError {
                // Only a missing endpoint is worth trying the next shape for. Anything else, an
                // expired token or an unreachable host, is the real answer and stops here.
                guard case .notFound = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    // There is deliberately NO deleteComment here, and there must never be one. Ticketbar can add
    // and edit comments; deleting is done in the browser, on purpose, where it takes more than one
    // click in a popover that opens under the cursor.

    /// Uploads an image and returns the filename Jira stored it under, which is what the wiki
    /// markup `!filename!` refers to.
    ///
    /// Attachments are the one endpoint that is not JSON: multipart, and Jira rejects the request
    /// without `X-Atlassian-Token: no-check`, which is its XSRF guard for file uploads.
    func attach(imageData: Data, filename: String, to issueKey: String) async throws -> String {
        guard let token = tokenProvider(), !token.isEmpty else { throw JiraError.notConfigured }
        let url = baseURL.appendingPathComponent("rest/api/2/issue/\(issueKey)/attachments")

        let boundary = "ticketbar-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let data = try await send(request)
        // The response is an array of the attachments created.
        struct Attachment: Decodable { let filename: String }
        guard let created = try? JSONDecoder().decode([Attachment].self, from: data).first else {
            throw JiraError.decodingFailed("The image uploaded, but the server did not name it.")
        }
        return created.filename
    }

    /// The browser URL for an issue, for the "Open in browser" link.
    func browseURL(for issueKey: String) -> URL {
        baseURL.appendingPathComponent("browse").appendingPathComponent(issueKey)
    }

    /// Where a user mints a PAT on Server/DC.
    var tokenPageURL: URL {
        baseURL.appendingPathComponent("secure/ViewProfile.jspa")
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [String: String], as type: T.Type) async throws -> T {
        let request = try makeRequest(path: path, query: query, method: "GET", body: nil)
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JiraError.decodingFailed("The server's answer was not in the expected shape.")
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        try await write(path, method: "POST", body: body)
    }

    private func put(_ path: String, body: [String: Any]) async throws {
        try await write(path, method: "PUT", body: body)
    }

    private func write(_ path: String, method: String, body: [String: Any]) async throws {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try makeRequest(path: path, query: [:], method: method, body: payload)
        _ = try await send(request)
    }

    private func makeRequest(path: String, query: [String: String], method: String, body: Data?) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else { throw JiraError.notConfigured }

        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingLeadingSlash()),
                                       resolvingAgainstBaseURL: false)
        // Encoded by hand against a strict set. URLComponents leaves "=", "(" and ")" literal in a
        // query value, which JQL is full of, and different proxies disagree about that.
        if !query.isEmpty {
            components?.percentEncodedQuery = query
                .sorted { $0.key < $1.key }
                .map { "\($0.key.strictlyEncoded())=\($0.value.strictlyEncoded())" }
                .joined(separator: "&")
        }
        guard let url = components?.url else {
            throw JiraError.unexpected("The base URL is not a valid address.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw JiraError.from(urlError: urlError)
        } catch {
            throw JiraError.unexpected(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JiraError.unexpected("The server did not answer with HTTP.")
        }
        #if DEBUG
        logInternalCall(request, status: http.statusCode, body: data)
        #endif
        // Jira Server answers an expired bearer token with a login page in some proxy setups, so
        // the status code is the only thing worth trusting here.
        let message = (try? JSONDecoder().decode(JiraErrorBody.self, from: data))?.firstMessage
        if let error = JiraError.from(statusCode: http.statusCode, message: message) { throw error }
        return data
    }

    #if DEBUG
    /// Logs the `/rest/internal/2` calls only, which are Jira's own undocumented UI API and have
    /// never been proven against this instance. The `Authorization` header is deliberately not
    /// touched here: the token is never printed, logged or put in an error message.
    private func logInternalCall(_ request: URLRequest, status: Int, body: Data) {
        guard let url = request.url, url.path.contains("/rest/internal/") else { return }
        let query = url.query.map { "?\($0)" } ?? ""
        let answer = String(data: body.prefix(400), encoding: .utf8) ?? "(not text)"
        let line = "[jira] \(request.httpMethod ?? "?") \(url.path)\(query) -> \(status) \(answer)\n"
        // Straight to the file handle: `print` to a pipe is block buffered, and the buffer never
        // flushed, so the first attempt at this logging produced nothing at all.
        FileHandle.standardError.write(Data(line.utf8))
    }
    #endif
}

private extension String {
    func trimmingLeadingSlash() -> String {
        hasPrefix("/") ? String(dropFirst()) : self
    }

    /// Percent-encodes everything outside RFC 3986 unreserved characters. Nothing in a JQL string
    /// then depends on a proxy's opinion about "=" or "+".
    func strictlyEncoded() -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: unreserved) ?? self
    }
}

extension URLRequest {
    /// A request dump safe to print. The Authorization header is replaced, never truncated: a
    /// prefix of a PAT is still a leak.
    var redactedDescription: String {
        var lines = ["\(httpMethod ?? "GET") \(url?.absoluteString ?? "<no url>")"]
        for (name, value) in allHTTPHeaderFields ?? [:] {
            let shown = name.caseInsensitiveCompare("Authorization") == .orderedSame ? "<redacted>" : value
            lines.append("\(name): \(shown)")
        }
        return lines.joined(separator: "\n")
    }
}
