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

/// Stepping from one board column to the next, for the swipe across the list header.
enum ColumnPaging {
    /// The column a swipe lands on, or nil when there is nowhere to go.
    ///
    /// The ends hold rather than wrapping around: a board is a line of columns from backlog to
    /// done, and jumping from Done back to Sprint Backlog on one more swipe reads as a glitch
    /// rather than as paging.
    static func column(after current: BoardColumn?,
                       in columns: [BoardColumn],
                       forward: Bool) -> BoardColumn? {
        guard !columns.isEmpty else { return nil }
        guard let current, let index = columns.firstIndex(of: current) else { return columns.first }

        let next = forward ? index + 1 : index - 1
        guard columns.indices.contains(next) else { return nil }
        return columns[next]
    }
}

extension BoardColumn {
    /// The name of the column that gathers a status.
    ///
    /// Used by the move menu, so a destination reads as the column the dropdown calls it: this
    /// workflow's transition says "Test" where the column is "Testing", and two names for one
    /// place is one too many. The name is passed through exactly as the board has it, emoji and
    /// all, and nothing is ever added to it.
    static func name(forStatusID id: String?, in columns: [BoardColumn]) -> String? {
        guard let id else { return nil }
        return columns.first { $0.statusIDs.contains(id) }?.name
    }
}

/// A move the user is offered: a transition, named by the board column it lands in.
///
/// Only moves that land in a column are offered. A workflow can transition an issue into a status
/// no column gathers, "Blocked" on this board, and showing that meant the menu listed a
/// destination the board has no place for, under a name that appears nowhere else in the app.
struct MoveOption: Identifiable, Hashable {
    let transition: JiraTransition
    let columnName: String

    var id: String { transition.id }

    static func options(from transitions: [JiraTransition],
                        columns: [BoardColumn]) -> [MoveOption] {
        transitions.compactMap { transition in
            guard let name = BoardColumn.name(forStatusID: transition.to?.id, in: columns) else {
                return nil
            }
            return MoveOption(transition: transition, columnName: name)
        }
    }
}
