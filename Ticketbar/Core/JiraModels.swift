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

// MARK: - Comments

struct JiraCommentsResponse: Decodable {
    let comments: [JiraComment]
}

struct JiraComment: Decodable, Identifiable, Hashable {
    let id: String
    let author: Author?
    /// The raw wiki markup. Only used when the server did not return a rendered body.
    let body: String?
    /// Present because the request asks for `expand=renderedBody`. Comments are wiki markup for
    /// the same reason descriptions are, so the server does the rendering.
    let renderedBody: String?
    let created: String?
    let updated: String?

    struct Author: Decodable, Hashable {
        /// The username. Stable, unlike `displayName`, which differs by transliteration
        /// ("Pouya" against "Pooya") and changes whenever somebody edits their profile.
        let name: String?
        let displayName: String?
    }

    var authorName: String { author?.displayName ?? "Unknown" }
    var createdDate: Date? { created.flatMap(JiraDateFormat.parseTimestamp) }

    /// Rendered HTML if the server gave it, otherwise the raw markup wrapped so it at least
    /// keeps its line breaks rather than collapsing into one paragraph.
    var html: String {
        if let rendered = renderedBody?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rendered.isEmpty {
            return rendered
        }
        let raw = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "<p>" + HTMLEscape.escape(raw).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
    }
}

extension JiraComment {
    /// The scheme the rendered thread uses to talk back to the app. `DescriptionWebView`
    /// intercepts it; nothing with this scheme ever reaches the network.
    static let actionScheme = "ticketbar"

    /// Composes every comment into one document: one web view for the whole thread instead of one
    /// per comment, which matters because a busy issue can carry twenty of them.
    ///
    /// Comments in `editableIDs` get an Edit link. There is deliberately NO delete link, and there
    /// must never be one: deleting a comment is done in the browser, where it takes more than one
    /// stray click in a popover that opens under the cursor.
    static func composedHTML(_ comments: [JiraComment],
                             editableIDs: Set<String> = [],
                             reactions: [String: [JiraReaction]] = [:],
                             now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        return comments.map { comment in
            let when = comment.createdDate.map { formatter.localizedString(for: $0, relativeTo: now) } ?? ""
            var meta = HTMLEscape.escape(comment.authorName)
            if !when.isEmpty { meta += " &middot; " + HTMLEscape.escape(when) }
            // Both must be present and actually differ. A comment that was never edited often
            // carries no `updated` at all, and nil != created would mark every one of them edited.
            if let updated = comment.updated, let created = comment.created, updated != created {
                meta += " &middot; edited"
            }

            // Reaction chips, then the picker, then Edit. Still no delete, ever.
            var chips = (reactions[comment.id] ?? [])
                .filter { $0.total > 0 }
                .map { reaction -> String in
                    let mine = reaction.currentUserReacted == true ? " jrm" : ""
                    let id = reaction.emojiId ?? ""
                    return "<a class=\"jr\(mine)\" href=\"\(actionScheme)://react/\(comment.id)/\(id)\">"
                        + "\(reaction.emoji) \(reaction.total)</a>"
                }
                .joined()
            chips += "<a class=\"jrp\" href=\"\(actionScheme)://picker/\(comment.id)\">&#x1F642;+</a>"

            var actions = "<div class=\"jce\">\(chips)"
            if editableIDs.contains(comment.id) {
                actions += "<a class=\"jcl\" href=\"\(actionScheme)://edit/\(comment.id)\">Edit</a>"
            }
            actions += "</div>"
            return "<div class=\"jc\"><div class=\"jcm\">\(meta)</div>\(comment.html)\(actions)</div>"
        }.joined()
    }
}

/// Author names and any raw markup are other people's text going into an HTML document, so they
/// are escaped rather than trusted.
enum HTMLEscape {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Reactions

/// Emoji reactions on a comment.
///
/// Server/DC serves these from `/rest/internal/2`, which is undocumented, so every field is
/// optional and decoding never throws. If the shape is not what this expects, the reaction row
/// is simply absent rather than taking the comment thread down with it.
struct JiraReactionsResponse: Decodable {
    let reactions: [JiraReaction]?
}

struct JiraReaction: Decodable, Identifiable, Hashable {
    /// A unicode codepoint in hex, for example "1f44d" for a thumbs up.
    let emojiId: String?
    let count: Int?
    let currentUserReacted: Bool?
    let users: [ReactionUser]?

    struct ReactionUser: Decodable, Hashable {
        let name: String?
        let displayName: String?
    }

    var id: String { emojiId ?? UUID().uuidString }

    var total: Int { count ?? users?.count ?? 0 }

    /// The codepoint rendered as the character it stands for.
    var emoji: String { JiraReaction.emoji(for: emojiId) }

    static func emoji(for id: String?) -> String {
        guard let id, let value = UInt32(id.replacingOccurrences(of: "U+", with: ""), radix: 16),
              let scalar = UnicodeScalar(value) else { return "\u{2753}" }
        return String(Character(scalar))
    }

    /// Hex codepoint for an emoji character, which is what the endpoint wants back.
    static func emojiId(for emoji: String) -> String? {
        guard let scalar = emoji.unicodeScalars.first else { return nil }
        return String(scalar.value, radix: 16)
    }

    /// The set offered by the picker. Deliberately short: a popover is not the place for a
    /// full emoji keyboard, and these are what a tracker actually sees used.
    static let palette = ["\u{1F44D}", "\u{1F44E}", "\u{1F389}", "\u{1F604}",
                          "\u{1F440}", "\u{2764}\u{FE0F}", "\u{1F680}", "\u{1F914}"]
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
