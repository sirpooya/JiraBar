import Foundation

// MARK: - Account

struct JiraUser: Decodable, Hashable {
    let name: String?
    let displayName: String
    let emailAddress: String?
    let active: Bool?
    /// Keyed by pixel size: "16x16", "24x24", "32x32", "48x48". Server/DC serves these from
    /// `/secure/useravatar`, on the Jira host and behind the same auth as everything else.
    let avatarUrls: [String: String]?

    /// The largest sensible source for a small circle. An 18 point avatar is 36 pixels on a
    /// retina display, so the 24 pixel image is the one that visibly softens.
    var avatarURL: URL? {
        for size in ["48x48", "32x32", "24x24", "16x16"] {
            if let raw = avatarUrls?[size], let url = URL(string: raw) { return url }
        }
        return nil
    }

    /// Drawn while the image loads, and instead of it when there is none. Initials from the
    /// display name, which is the only name a Jira user is guaranteed to have.
    var initials: String {
        let words = displayName.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
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
        /// Nil for an unassigned issue, which is a normal state on this board rather than an error.
        let assignee: JiraUser?
        /// Tech Area. A Jira select field, so it arrives as an object with a `value`, but the
        /// same field can be a bare string or an array depending on how it was configured.
        let techArea: CustomFieldValue?

        private enum CodingKeys: String, CodingKey {
            case summary, description, status, priority, issuetype, updated, duedate, parent
            case assignee
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
        /// Present on priority: the icon Jira itself draws for it. See `JiraIconAsset`.
        let iconUrl: String?
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

/// One issue with every field, plus the map from field id to display name.
struct IssueFieldsResponse: Decodable {
    let fields: [String: JSONValue]?
    let names: [String: String]?
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
    /// - Parameter offersReactions: false on an instance with no reactions API, which takes the
    ///   picker off the thread rather than leaving a control that answers "Not found on this
    ///   server" every time it is used.
    static func composedHTML(_ comments: [JiraComment],
                             editableIDs: Set<String> = [],
                             reactions: [String: [JiraReaction]] = [:],
                             offersReactions: Bool = true,
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
            // `data-comment` as well as the href: the page posts the chip's position so the
            // picker can open beside it, and falls back to the link if that script never runs.
            if offersReactions {
            chips += "<a class=\"jrp\" data-comment=\"\(comment.id)\" "
                + "href=\"\(actionScheme)://picker/\(comment.id)\" "
                + "title=\"Add a reaction\">\(addReactionGlyph)</a>"
            }

            var actions = "<div class=\"jce\">\(chips)"
            if editableIDs.contains(comment.id) {
                actions += "<a class=\"jcl\" href=\"\(actionScheme)://edit/\(comment.id)\">Edit</a>"
            }
            actions += "</div>"
            // `dir="auto"` on the byline and on the body, separately: direction is resolved per
            // element from its own first strong character, so a Persian comment reads right to
            // left and an English one beside it is unaffected. Without it both render in the
            // document's left-to-right base direction, which reorders the runs of a Persian
            // sentence and makes it look scrambled to anyone who reads Persian.
            return "<div class=\"jc\"><div class=\"jcm\" dir=\"auto\">\(meta)</div>"
                + "<div class=\"jcb\" dir=\"auto\">\(comment.html)</div>\(actions)</div>"
        }.joined()
    }

    /// A neutral outline, not an emoji. This used to be a literal slightly-smiling face, which sat
    /// in the same row as the real reaction chips and read as a reaction somebody had already
    /// added. Jira's own control is a plain monochrome icon for the same reason.
    private static let addReactionGlyph = """
    <svg class="jrpi" viewBox="0 0 16 16" aria-hidden="true"><circle cx="6.9" cy="8.4" r="5.3"     fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="5.1" cy="7" r="0.85"     fill="currentColor"/><circle cx="8.7" cy="7" r="0.85" fill="currentColor"/><path     d="M4.6 10.1c0.6 0.9 1.4 1.3 2.3 1.3s1.7-0.4 2.3-1.3" fill="none" stroke="currentColor"     stroke-width="1.3" stroke-linecap="round"/><path d="M13 1.6v3.5M11.25 3.35h3.5"     stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>
    """
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
