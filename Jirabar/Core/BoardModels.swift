import Foundation

/// The Agile API's view of a board. Server/DC exposes it at `/rest/agile/1.0`, separately from
/// the `/rest/api/2` endpoints the rest of the app uses.
struct AgileBoard: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let type: String?
}

struct AgileBoardsResponse: Decodable {
    let values: [AgileBoard]
}

/// A board's column layout.
///
/// Read from the server rather than hardcoded, because a board column is not the same thing as a
/// status: one column can gather several statuses (a "Planning" column holding both Planning Web
/// and Planning App), and the board owner can rearrange them without telling anyone.
struct BoardConfiguration: Decodable {
    let id: Int
    let name: String
    let columnConfig: ColumnConfig

    struct ColumnConfig: Decodable {
        let columns: [RawColumn]
    }

    struct RawColumn: Decodable {
        let name: String
        let statuses: [StatusRef]?

        struct StatusRef: Decodable {
            let id: String
        }
    }

    /// Columns with no statuses mapped to them cannot be queried and are dropped: the board shows
    /// them as empty holding pens, and offering one in the dropdown would only ever return
    /// nothing, which would look exactly like the bug this app is built to avoid.
    var columns: [BoardColumn] {
        columnConfig.columns.compactMap { raw in
            let ids = (raw.statuses ?? []).map(\.id)
            guard !ids.isEmpty else { return nil }
            return BoardColumn(name: raw.name, statusIDs: ids)
        }
    }
}

/// One selectable column.
struct BoardColumn: Codable, Identifiable, Hashable {
    let name: String
    /// Status ids, not names: JQL accepts them and they survive a status being renamed.
    var statusIDs: [String] = []

    var id: String { name }

    /// `status in (...)`, which is how a column that gathers several statuses is expressed.
    var statusClause: String {
        "status in (" + statusIDs.joined(separator: ", ") + ")"
    }
}

/// The JQL for one column's issues.
extension BoardColumn {
    func jql(projectKey: String) -> String {
        "project = \(projectKey) AND \(statusClause) ORDER BY updated DESC"
    }

    /// True when the column gathers more than one status, so a row's own status still says
    /// something. In a single-status column every row would just repeat the dropdown above it.
    var gathersMultipleStatuses: Bool { statusIDs.count > 1 }

    /// Namespaces this column's seen-issue set. Without it, switching columns would diff the new
    /// column's issues against the previous column's set and notify for every one of them.
    ///
    /// Reduced to ASCII letters, digits and dashes, because the real board names them with emoji
    /// ("🟠 Working on it") and those become UserDefaults keys.
    var seenNamespace: String {
        let slug = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true)
        return collapsed.isEmpty ? "column" : collapsed.joined(separator: "-")
    }
}
