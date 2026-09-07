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
    /// Status ids, preferred: JQL accepts them and they survive a status being renamed.
    var statusIDs: [String] = []
    /// Names, used only by the fallback below when the Agile API is not available.
    var statusNames: [String] = []

    var id: String { name }

    /// `status in (...)`, which is how a column that gathers several statuses is expressed.
    var statusClause: String {
        if !statusIDs.isEmpty {
            return "status in (" + statusIDs.joined(separator: ", ") + ")"
        }
        return "status in (" + statusNames.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
    }

    /// Used when the Agile API is unavailable (some Server/DC instances lock it down, and it
    /// answers 404 rather than saying so). These are the DDS workflow statuses recorded in
    /// CLAUDE.md, one column each. Less accurate than the real board, and clearly better than
    /// offering no columns at all.
    static let fallback: [BoardColumn] = [
        "Sprint Backlog", "Planning Web", "Planning App", "In-Progress",
        "Storybook", "Testing", "Blocked / Rejected", "UAT", "Done",
    ].map { BoardColumn(name: $0, statusNames: [$0]) }
}

/// The JQL for one column's issues.
extension BoardColumn {
    func jql(projectKey: String) -> String {
        "project = \(projectKey) AND \(statusClause) ORDER BY updated DESC"
    }

    /// Namespaces this column's seen-issue set. Without it, switching columns would diff the new
    /// column's issues against the previous column's set and notify for every one of them.
    var seenNamespace: String {
        name.replacingOccurrences(of: " ", with: "-").lowercased()
    }
}
