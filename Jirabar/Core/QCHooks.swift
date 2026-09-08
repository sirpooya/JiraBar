import Foundation

/// Launch flags that force a state on screen without touching the server.
///
/// The three failure states are the reason this exists: proving that a rejected token does not
/// render as an empty list means putting all four states side by side in a screenshot, and two of
/// them are awkward to produce on demand against a live server.
///
///     Jirabar.app/Contents/MacOS/Jirabar --qc-state=token-rejected
///
/// Values: `sample`, `empty`, `loading`, `needs-token`, `token-rejected`, `unreachable`, `failed`.
/// DEBUG only. A release build ignores the flag entirely.
enum QCHooks {

    static func forcedState(from arguments: [String] = CommandLine.arguments) -> ContentState? {
        #if DEBUG
        guard let raw = arguments
            .first(where: { $0.hasPrefix("--qc-state=") })?
            .replacingOccurrences(of: "--qc-state=", with: "") else { return nil }

        switch raw {
        case "sample", "detail": return .from(sampleIssues)
        case "empty": return .empty
        case "loading": return .loading
        case "needs-token": return .needsToken
        case "token-rejected": return .tokenRejected
        case "unreachable": return .unreachable("The host name does not resolve.")
        case "failed": return .failed("Jira answered 503. The server is having a problem, not this Mac.")
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Board 95's real columns, as read from works.digikala.com on 2026-09-08. A fixture for the
    /// forced-state builds only. The shipping path never substitutes a column list: if the board
    /// cannot be read, the popover says so.
    static let qcColumns: [BoardColumn] = [
        BoardColumn(name: "Backlog", statusIDs: ["10108"]),
        BoardColumn(name: "To Do", statusIDs: ["10004"]),
        BoardColumn(name: "\u{1F7E0} Working on it", statusIDs: ["3"]),
        BoardColumn(name: "\u{1F7E3} QC Ready", statusIDs: ["10013"]),
        BoardColumn(name: "\u{1F535} Testing", statusIDs: ["10406"]),
        BoardColumn(name: "\u{1F534} Rejected", statusIDs: ["10107"]),
        BoardColumn(name: "\u{1F7E2} Done", statusIDs: ["10003"]),
    ]

    /// Fixture transitions, so the staged move control can be photographed. Named after board
    /// 95's real columns.
    static var sampleTransitions: [String: [JiraTransition]] {
        let json = """
        {"transitions":[
          {"id":"11","name":"\u{1F7E3} QC Ready","to":{"name":"QC Ready","statusCategory":{"key":"indeterminate"}}},
          {"id":"21","name":"\u{1F535} Testing","to":{"name":"Testing","statusCategory":{"key":"indeterminate"}}},
          {"id":"31","name":"\u{1F534} Rejected","to":{"name":"Rejected","statusCategory":{"key":"new"}}},
          {"id":"41","name":"\u{1F7E2} Done","to":{"name":"Done","statusCategory":{"key":"done"}}}]}
        """.data(using: .utf8)!
        guard let decoded = try? JSONDecoder().decode(JiraTransitionsResponse.self, from: json) else {
            return [:]
        }
        return ["DDS-412": decoded.transitions]
    }

    /// Fixture reactions, so the chips can be photographed.
    static var sampleReactions: [String: [JiraReaction]] {
        let json = """
        {"reactions":[{"emojiId":"1f44d","count":2,"currentUserReacted":true},
                      {"emojiId":"1f389","count":1,"currentUserReacted":false}]}
        """.data(using: .utf8)!
        guard let decoded = try? JSONDecoder().decode(JiraReactionsResponse.self, from: json),
              let list = decoded.reactions else { return [:] }
        return ["1": list, "11": list]
    }

    /// The issue the detail view should open on, for `--qc-state=detail`.
    static func forcedSelection(from arguments: [String] = CommandLine.arguments) -> String? {
        #if DEBUG
        return arguments.contains("--qc-state=detail") ? sampleIssues.first?.key : nil
        #else
        return nil
        #endif
    }

    /// Fixtures decoded from real response shapes rather than built with a memberwise init, so
    /// they double as a check that the decoder still matches what Jira sends.
    static let sampleIssues: [JiraIssue] = {
        guard let data = sampleJSON.data(using: .utf8),
              let response = try? JSONDecoder().decode(JiraSearchResponse.self, from: data) else {
            return []
        }
        return response.issues
    }()

    /// Fixture comments for the forced-state builds, keyed by issue.
    static var sampleComments: [String: [JiraComment]] {
        guard let data = sampleCommentsJSON.data(using: .utf8),
              let response = try? JSONDecoder().decode(JiraCommentsResponse.self, from: data) else {
            return [:]
        }
        return ["DDS-412": response.comments]
    }

    private static var sampleCommentsJSON: String { """
    {"comments": [
      {"id": "1", "author": {"name": "s.ahmadi", "displayName": "Sara Ahmadi"},
       "created": "\(timestamp(26))",
       "renderedBody": "<p>Snap radius of 8px feels tight on a 320px track. Can we make it proportional?</p>"},
      {"id": "2", "author": {"name": "p.kamel", "displayName": "Pouya Kamel"},
       "created": "\(timestamp(4))",
       "renderedBody": "<p>Agreed. Using <code>max(8, trackWidth * 0.025)</code> instead.</p>"}
    ]}
    """
    }

    /// Relative to the day the QC pass runs, so the fixture always shows one overdue, one due
    /// today and one with no date, rather than drifting into "everything is overdue" after a week.
    private static func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestamp(_ hoursAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.string(from: date)
    }

    private static var sampleJSON: String { """
    {
      "total": 4,
      "issues": [
        {
          "id": "100001",
          "key": "DDS-412",
          "fields": {
            "summary": "Range slider magnet snap 🌐",
            "status": {"id": "3", "name": "In Progress", "statusCategory": {"key": "indeterminate", "colorName": "yellow"}},
            "priority": {"id": "2", "name": "High"},
            "issuetype": {"name": "Task", "subtask": false},
            "updated": "\(timestamp(2))",
            "duedate": "\(day(0))",
            "parent": {"key": "DDS-100", "fields": {"summary": "Form controls"}},
            "customfield_10411": {"value": "Web"}
          },
          "renderedFields": {
            "description": "<p>The handle should snap to the nearest tick when released within 8px.</p><ul><li>Ticks every 10 units</li><li>Animation 160ms ease-out</li></ul>"
          }
        },
        {
          "id": "100002",
          "key": "DDS-407",
          "fields": {
            "summary": "Bottom sheet drag dismiss 📱",
            "status": {"id": "10108", "name": "Backlog", "statusCategory": {"key": "new", "colorName": "blue-gray"}},
            "priority": {"id": "3", "name": "Medium"},
            "issuetype": {"name": "Story", "subtask": false},
            "updated": "\(timestamp(20))",
            "duedate": null,
            "customfield_10411": {"value": "Mobile"}
          },
          "renderedFields": {"description": "<p>Dragging below 40 percent of the sheet height dismisses it.</p>"}
        },
        {
          "id": "100003",
          "key": "DDS-398",
          "fields": {
            "summary": "Token audit for elevation ramp",
            "status": {"id": "10013", "name": "QC Ready", "statusCategory": {"key": "indeterminate", "colorName": "yellow"}},
            "priority": {"id": "4", "name": "Low"},
            "issuetype": {"name": "Task", "subtask": false},
            "updated": "\(timestamp(70))",
            "duedate": "\(day(3))",
            "customfield_10411": null
          },
          "renderedFields": {"description": "<p>Every shadow leaf must alias a primitive.</p><table><tr><th>Level</th><th>Blur</th></tr><tr><td>1</td><td>2px</td></tr></table>"}
        },
        {
          "id": "100004",
          "key": "DDS-377",
          "fields": {
            "summary": "Chip group overflow rules 🌐",
            "status": {"id": "10107", "name": "Rejected", "statusCategory": {"key": "new", "colorName": "blue-gray"}},
            "priority": {"id": "1", "name": "Highest"},
            "issuetype": {"name": "Bug", "subtask": false},
            "updated": "\(timestamp(150))",
            "duedate": "\(day(-2))",
            "customfield_10411": {"value": "Web"}
          },
          "renderedFields": {"description": "<p>Chips past the third wrap instead of scrolling.</p><pre><code>overflow: hidden;</code></pre>"}
        }
      ]
    }
    """
    }
}
