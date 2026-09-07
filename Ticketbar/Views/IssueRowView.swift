import SwiftUI

struct IssueRowView: View {
    let issue: JiraIssue
    /// False when the selected column maps to a single status, because then every row would carry
    /// the same pill the dropdown above the list already shows.
    let showsStatus: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    // There is deliberately no Done button on a row. It used to sit here as a checkmark that
    // transitioned the issue on a single click, with no confirmation, in a popover that opens
    // under the cursor. Moving an issue now happens in the detail view, where you have opened the
    // thing you are about to change.

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                // Two lines, not three: key, status and platform share one metadata line above the
                // title. The key leads it, because it is the thing you quote to somebody else.
                HStack(spacing: 6) {
                    Text(issue.key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if showsStatus {
                        StatusPill(name: issue.statusName,
                                   categoryKey: issue.fields.status?.statusCategory?.key)
                    }
                    if let platform = issue.platform {
                        PlatformPill(platform: platform)
                    }
                    Spacer(minLength: 0)
                    DueBadge(due: issue.dueDate)
                }

                Text(issue.cleanSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(issue.key), \(issue.cleanSummary), \(issue.statusName)")
    }
}

struct StatusPill: View {
    let name: String
    let categoryKey: String?

    /// Colored from Jira's status *category*, which is stable, rather than from the status name,
    /// which is per workflow scheme and would need a lookup table per project.
    private var tint: Color {
        switch categoryKey {
        case "done": return .green
        case "indeterminate": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.14)))
    }
}

struct PlatformPill: View {
    let platform: Platform

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: platform.symbolName)
                .font(.system(size: 8, weight: .semibold))
            Text(platform.label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct DueBadge: View {
    let due: Date?

    var body: some View {
        if let due {
            let calendar = Calendar.current
            let isOverdue = calendar.startOfDay(for: due) < calendar.startOfDay(for: Date())
            let isToday = calendar.isDateInToday(due)
            Text(label(for: due, isOverdue: isOverdue, isToday: isToday))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOverdue ? Color.red : (isToday ? Color.orange : Color.secondary))
        }
    }

    private func label(for due: Date, isOverdue: Bool, isToday: Bool) -> String {
        if isToday { return "Due today" }
        if isOverdue { return "Overdue" }
        return due.formatted(.dateTime.day().month(.abbreviated))
    }
}
