import Foundation

/// A value from Jira decoded without knowing its shape.
///
/// The fields on this board arrive as every shape Jira has: a bare string for a label, a number
/// for Story Points, `{"name": "PDP"}` for a component, `{"value": "Mobile"}` for a select, and an
/// array of any of those. Story Points is also a custom field whose id differs per instance, so
/// the id cannot be hardcoded and the value has to be read without a matching Swift type.
indirect enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    /// One short line, or nil when there is nothing worth showing.
    var displayText: String? {
        switch self {
        case .null:
            return nil
        case .bool(let value):
            return value ? "Yes" : "No"
        case .number(let value):
            // Story points are "4", not "4.0", but a half point is still a half point.
            return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let values):
            let parts = values.compactMap(\.displayText)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object(let fields):
            // Jira names the readable part differently depending on the field's type.
            for key in ["name", "value", "displayName"] {
                if let text = fields[key]?.displayText { return text }
            }
            // A parent is an issue, not a value: "DDS-410 Tile Tab, Tab Bar". This is what a
            // sub-task's story, and a task's, is read from.
            if let key = fields["key"]?.displayText {
                guard case .object(let inner)? = fields["fields"],
                      let summary = inner["summary"]?.displayText else { return key }
                return "\(key)  \(summary)"
            }
            return nil
        }
    }
}

struct IssueFieldRow: Hashable {
    let label: String
    let value: String

    /// The individual values, for the fields that hold a list of them.
    var values: [String] {
        value.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// Components and labels are tags in Jira and read as tags here: one chip each, rather than
    /// a comma separated line that has to be parsed by eye.
    var isTagList: Bool {
        label == "Component/s" || label == "Labels"
    }
}

enum IssueFieldRows {
    /// Shown in this order, under the chips. Jira's own display names, matched against the `names`
    /// map the server returns, so the custom field ids never appear in this app.
    static let wanted = ["Parent", "Epic Link", "Affects Version/s",
                         "Component/s", "Labels", "Story Points"]

    /// - Parameters:
    ///   - fields: the issue's `fields` object, keyed by field id.
    ///   - names: field id to display name, from `expand=names`.
    static func rows(fields: [String: JSONValue], names: [String: String]) -> [IssueFieldRow] {
        wanted.compactMap { wantedName in
            guard let id = names.first(where: { $0.value == wantedName })?.key,
                  let text = fields[id]?.displayText else { return nil }
            return IssueFieldRow(label: wantedName, value: text)
        }
    }
}
