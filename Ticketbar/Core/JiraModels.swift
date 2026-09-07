import Foundation

// MARK: - Account

struct JiraUser: Decodable, Equatable {
    let name: String?
    let displayName: String
    let emailAddress: String?
    let active: Bool?
}

// MARK: - Search

struct JiraSearchResponse: Decodable {
    let total: Int
    let issues: [JiraIssue]
}

struct JiraIssue: Decodable, Identifiable, Hashable {
    let id: String
    let key: String
    let fields: Fields
    /// Present only because the search asks for `expand=renderedFields`. Jira returns the wiki
    /// markup already rendered to HTML here; `fields.description` is the raw markup.
    let renderedFields: RenderedFields?

    struct Fields: Decodable, Hashable {
        let summary: String
        let description: String?
        let status: NamedRef?
        let priority: NamedRef?
        let issuetype: IssueType?
        let updated: String?
        let duedate: String?
        let parent: Parent?
        /// Tech Area. A Jira select field, so it arrives as an object with a `value`, but the
        /// same field can be a bare string or an array depending on how it was configured.
        let techArea: CustomFieldValue?

        private enum CodingKeys: String, CodingKey {
            case summary, description, status, priority, issuetype, updated, duedate, parent
            case techArea = "customfield_10411"
        }
    }

    struct RenderedFields: Decodable, Hashable {
        let description: String?
    }

    struct NamedRef: Decodable, Hashable {
        let id: String?
        let name: String
        let statusCategory: StatusCategory?
    }

    struct StatusCategory: Decodable, Hashable {
        /// One of `new`, `indeterminate`, `done`. Stable across workflow schemes, unlike the name.
        let key: String?
        let colorName: String?
    }

    struct IssueType: Decodable, Hashable {
        let name: String
        let subtask: Bool?
        let iconUrl: String?
    }

    struct Parent: Decodable, Hashable {
        let key: String
        let fields: ParentFields?

        struct ParentFields: Decodable, Hashable {
            let summary: String?
        }
    }

    var statusName: String { fields.status?.name ?? "Unknown" }
    var isDone: Bool { fields.status?.statusCategory?.key == "done" }
    var descriptionHTML: String? {
        let html = renderedFields?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (html?.isEmpty == false) ? html : nil
    }
    var platform: Platform? {
        Platform.detect(techArea: fields.techArea?.stringValue, summary: fields.summary)
    }
    /// The summary with the platform emoji suffix removed, so the row does not show the platform
    /// twice once the pill is drawn.
    var cleanSummary: String { Platform.strippingMarker(from: fields.summary) }

    var updatedDate: Date? { fields.updated.flatMap(JiraDateFormat.parseTimestamp) }
    var dueDate: Date? { fields.duedate.flatMap(JiraDateFormat.parseDay) }
}

/// A Jira custom field that can arrive as a string, as `{"value": "Web"}`, or as an array of
/// either. Decoding the wrong shape would throw and take the whole search response with it, so
/// this absorbs all four and yields nil rather than failing.
struct CustomFieldValue: Decodable, Hashable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            stringValue = text
        } else if let object = try? container.decode(ValueObject.self) {
            stringValue = object.value
        } else if let list = try? container.decode([ValueObject].self) {
            stringValue = list.first?.value
        } else if let list = try? container.decode([String].self) {
            stringValue = list.first
        } else {
            stringValue = nil
        }
    }

    private struct ValueObject: Decodable {
        let value: String?
    }
}

// MARK: - Transitions

struct JiraTransitionsResponse: Decodable {
    let transitions: [JiraTransition]
}

struct JiraTransition: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let to: Target?
    /// Present because the request asks for `expand=transitions.fields`. A workflow that demands
    /// a resolution or a comment on the way to Done cannot be driven from a one-button popover,
    /// and finding that out from a 400 after the click is a worse experience than saying so first.
    let fields: [String: TransitionField]?

    struct Target: Decodable, Hashable {
        let id: String?
        let name: String?
        let statusCategory: JiraIssue.StatusCategory?
    }

    struct TransitionField: Decodable, Hashable {
        let required: Bool?
        let name: String?
        let hasDefaultValue: Bool?
    }

    /// Fields Jira will refuse the transition without, and cannot fill in itself.
    var blockingFieldNames: [String] {
        (fields ?? [:])
            .filter { $0.value.required == true && $0.value.hasDefaultValue != true }
            .map { $0.value.name ?? $0.key }
            .sorted()
    }

    /// True when this transition lands in Jira's `done` category. Matching the category beats
    /// matching the literal name "Done": the id differs per workflow scheme and so can the name.
    var landsInDone: Bool {
        if to?.statusCategory?.key == "done" { return true }
        return (to?.name ?? name).caseInsensitiveCompare("Done") == .orderedSame
    }
}

// MARK: - Errors as Jira sends them

struct JiraErrorBody: Decodable {
    let errorMessages: [String]?
    let errors: [String: String]?

    var firstMessage: String? {
        if let message = errorMessages?.first, !message.isEmpty { return message }
        return errors?.values.first
    }
}

// MARK: - Dates

enum JiraDateFormat {
    /// Jira Server sends `2026-09-02T11:04:33.000+0330`, which ISO8601DateFormatter rejects
    /// because of the milliseconds plus the unseparated offset.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseTimestamp(_ text: String) -> Date? { timestamp.date(from: text) }
    static func parseDay(_ text: String) -> Date? { day.date(from: text) }
}
