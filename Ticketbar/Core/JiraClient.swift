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
            "fields": "summary,description,status,priority,issuetype,updated,duedate,parent,customfield_10411",
            "expand": "renderedFields",
            "maxResults": String(maxResults),
        ]
        let response = try await get("/rest/api/2/search", query: query, as: JiraSearchResponse.self)
        return response.issues
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

    func addComment(_ text: String, to issueKey: String) async throws {
        try await post("/rest/api/2/issue/\(issueKey)/comment", body: ["body": text])
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
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try makeRequest(path: path, query: [:], method: "POST", body: payload)
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
        // Jira Server answers an expired bearer token with a login page in some proxy setups, so
        // the status code is the only thing worth trusting here.
        let message = (try? JSONDecoder().decode(JiraErrorBody.self, from: data))?.firstMessage
        if let error = JiraError.from(statusCode: http.statusCode, message: message) { throw error }
        return data
    }
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
