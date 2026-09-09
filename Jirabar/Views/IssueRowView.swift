import SwiftUI

struct IssueRowView: View {
    let issue: JiraIssue
    @Bindable var store: IssueStore
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
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    // Two lines, not three: key, status and platform share one metadata line
                    // above the title. The key leads it, because it is the thing you quote to
                    // somebody else.
                    HStack(spacing: 6) {
                        // Jira's own icon for the type, leading the row the way it leads a card
                        // on the board. No text beside it: the shape is the whole point, and the
                        // detail view spells it out.
                        JiraIcon(url: issue.fields.issuetype?.iconUrl,
                                 kind: .issueType,
                                 label: issue.fields.issuetype?.name,
                                 store: store)
                        Text(issue.key)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if showsStatus {
                            StatusPill(name: issue.statusName,
                                       categoryKey: issue.fields.status?.statusCategory?.key)
                        }
                        if let platform = issue.platform {
                            PlatformPill(platform: platform)
                        }
                        // The story this belongs to. A task on its own says what changed but not
                        // what it is part of, and the board groups them by the story.
                        if let parent = issue.fields.parent {
                            ParentTag(parent: parent)
                        }
                        Spacer(minLength: 0)
                        DueBadge(due: issue.dueDate)
                    }

                    Text(issue.cleanSummary)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Trailing, and centred on the row rather than on either line: the avatar answers
                // "whose is this", which belongs to the whole row and not to the metadata line.
                AssigneeAvatar(user: issue.fields.assignee, store: store)
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
        .accessibilityLabel(accessibilityDescription)
        // Right-click to move, without opening the issue first.
        //
        // This is not the one-click Done control that used to sit on a row and was removed: that
        // moved somebody's issue on a single stray click in a popover that opens under the
        // pointer. A right-click and then a choice from a menu is two deliberate acts.
        .contextMenu {
            let moves = MoveOption.options(from: store.transitionsByKey[issue.key] ?? [],
                                           columns: store.columns)
            if moves.isEmpty {
                // The menu's contents are built when it opens, so a hover that has not finished
                // loading yet says so rather than showing an empty menu.
                Text("Loading moves...")
            } else {
                Section("Move \(issue.key) to") {
                    ForEach(moves) { move in
                        Button(move.columnName) {
                            Task { await store.apply(move.transition, to: issue.key) }
                        }
                    }
                }
            }
        }
        // Loaded on hover, so the moves are there by the time the menu opens. One request per row
        // the pointer actually crosses, cached after that, rather than fifty on every refresh.
        .onHover { inside in
            guard inside else { return }
            Task { await store.loadTransitions(for: issue.key) }
        }
    }
}

extension IssueRowView {
    fileprivate var accessibilityDescription: String {
        var parts = [issue.key, issue.cleanSummary, issue.statusName]
        if let assignee = issue.fields.assignee {
            parts.append("assigned to \(assignee.displayName)")
        }
        return parts.joined(separator: ", ")
    }
}

/// The assignee, as Jira draws them: a small circle at the trailing edge of the row.
///
/// The image is fetched through the client rather than by the view, because on a private instance
/// it sits behind the same token as everything else. Until it arrives, and if it never does, the
/// circle holds the assignee's initials.
struct AssigneeAvatar: View {
    /// Nil for an unassigned issue, which draws the placeholder rather than nothing: the trailing
    /// slot stays the same width down the list instead of the rows jostling.
    let user: JiraUser?
    @Bindable var store: IssueStore

    private let side: CGFloat = 20
    private var avatarKey: String? { user?.avatarURL?.absoluteString }

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.09))
            content
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .help(user?.displayName ?? "Unassigned")
        .accessibilityLabel(user.map { "Assigned to \($0.displayName)" } ?? "Unassigned")
        .task(id: avatarKey) {
            guard let user else { return }
            await store.loadAvatar(for: user)
        }
    }

    /// Three cases, in order of how much they say: the picture, the person's initials, and a
    /// generic head for an issue nobody owns. Plenty of Jira accounts have never had an avatar
    /// uploaded, so the initials are a normal outcome rather than a failure.
    @ViewBuilder
    private var content: some View {
        if let user, let data = store.avatar(for: user), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let user {
            Text(user.initials)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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

/// One of Jira's own icons, from the bundle when it is a named file and from the server when it
/// is not.
///
/// Both paths are needed. The icons under `/images/icons` are SVG, which `NSImage` cannot decode
/// at runtime, so those have to be compiled into an asset catalog. An instance also picks its own
/// avatar for a type (`/secure/viewavatar?avatarId=10318` for Task on this one), which is a PNG
/// that no bundled name could ever match, so that one is fetched with the token like an avatar.
struct JiraIcon: View {
    let url: String?
    let kind: JiraIconAsset.Kind
    let label: String?
    @Bindable var store: IssueStore
    var side: CGFloat = 12

    var body: some View {
        if let asset = JiraIconAsset.name(forIconURL: url, kind: kind), NSImage(named: asset) != nil {
            icon(Image(asset))
        } else if let data = store.icon(for: url), let image = NSImage(data: data) {
            icon(Image(nsImage: image))
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: url) { await store.loadIcon(at: url) }
        }
    }

    private func icon(_ image: Image) -> some View {
        image
            .resizable()
            .frame(width: side, height: side)
            .help(label ?? "")
    }
}

/// The parent story on a task's row, named rather than keyed: "DDS-410" identifies nothing at a
/// glance, and the summary is what anyone actually recognises. The key is in the tooltip.
struct ParentTag: View {
    let parent: JiraIssue.Parent

    var body: some View {
        Text(parent.fields?.summary ?? parent.key)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("\(parent.key)  \(parent.fields?.summary ?? "")")
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
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        // Never squeezed: given less room than it needs, the label wrapped mid-word and the
        // capsule turned into a two-line blob beside the title.
        .fixedSize()
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
