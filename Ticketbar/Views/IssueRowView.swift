import SwiftUI

struct IssueRowView: View {
    let issue: JiraIssue
    let isBusy: Bool
    let onSelect: () -> Void
    let onDone: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(issue.key)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let platform = issue.platform {
                            PlatformPill(platform: platform)
                        }
                        Spacer(minLength: 0)
                        DueBadge(due: issue.dueDate)
                    }
                    Text(issue.cleanSummary)
                        // Medium, not regular: the summary is what the row is about, and beside a
                        // bold monospaced key at .secondary a regular weight reads as the quieter
                        // of the two.
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusPill(name: issue.statusName,
                               categoryKey: issue.fields.status?.statusCategory?.key)
                }

                doneButton
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

    @ViewBuilder
    private var doneButton: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Button(action: onDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .help("Move to Done")
            .accessibilityLabel("Move \(issue.key) to Done")
        }
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
