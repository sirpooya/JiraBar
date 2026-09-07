import Foundation

/// Launch flags that force a state on screen without touching the server.
///
/// The three failure states are the reason this exists: proving that a rejected token does not
/// render as an empty list means putting all four states side by side in a screenshot, and two of
/// them are awkward to produce on demand against a live server.
///
///     Ticketbar.app/Contents/MacOS/Ticketbar --qc-state=token-rejected
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
        case "sample": return .from(sampleIssues)
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

    /// Fixtures decoded from real response shapes rather than built with a memberwise init, so
    /// they double as a check that the decoder still matches what Jira sends.
    static let sampleIssues: [JiraIssue] = {
        guard let data = sampleJSON.data(using: .utf8),
              let response = try? JSONDecoder().decode(JiraSearchResponse.self, from: data) else {
            return []
        }
        return response.issues
    }()

    private static let sampleJSON = """
    {
      "total": 4,
      "issues": [
        {
          "id": "100001",
          "key": "DDS-412",
          "fields": {
            "summary": "Range slider magnet snap 🌐",
            "status": {"id": "3", "name": "In-Progress", "statusCategory": {"key": "indeterminate", "colorName": "yellow"}},
            "priority": {"id": "2", "name": "High"},
            "issuetype": {"name": "Task", "subtask": false},
            "updated": "2026-09-02T09:12:44.000+0330",
            "duedate": "2026-09-04",
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
            "status": {"id": "1", "name": "Sprint Backlog", "statusCategory": {"key": "new", "colorName": "blue-gray"}},
            "priority": {"id": "3", "name": "Medium"},
            "issuetype": {"name": "Story", "subtask": false},
            "updated": "2026-09-01T17:40:02.000+0330",
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
            "status": {"id": "5", "name": "UAT", "statusCategory": {"key": "indeterminate", "colorName": "yellow"}},
            "priority": {"id": "4", "name": "Low"},
            "issuetype": {"name": "Task", "subtask": false},
            "updated": "2026-08-28T11:05:19.000+0330",
            "duedate": "2026-08-30",
            "customfield_10411": null
          },
          "renderedFields": {"description": "<p>Every shadow leaf must alias a primitive.</p><table><tr><th>Level</th><th>Blur</th></tr><tr><td>1</td><td>2px</td></tr></table>"}
        },
        {
          "id": "100004",
          "key": "DDS-377",
          "fields": {
            "summary": "Chip group overflow rules 🌐",
            "status": {"id": "6", "name": "Blocked / Rejected", "statusCategory": {"key": "new", "colorName": "blue-gray"}},
            "priority": {"id": "1", "name": "Highest"},
            "issuetype": {"name": "Bug", "subtask": false},
            "updated": "2026-08-24T08:22:00.000+0330",
            "duedate": "2026-08-20",
            "customfield_10411": {"value": "Web"}
          },
          "renderedFields": {"description": "<p>Chips past the third wrap instead of scrolling.</p><pre><code>overflow: hidden;</code></pre>"}
        }
      ]
    }
    """
}
