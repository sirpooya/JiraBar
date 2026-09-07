import SwiftUI

struct IssueDetailView: View {
    let issue: JiraIssue
    @Bindable var store: IssueStore
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Keys.showDescription) private var showDescription = true
    @AppStorage(Keys.showComments) private var showComments = true
    @AppStorage(Keys.showMetadata) private var showMetadata = true
    @State private var descriptionHeight: CGFloat = 60
    @State private var commentsHeight: CGFloat = 40
    /// Chosen but not yet applied. Nothing reaches the server until Move is pressed.
    @State private var stagedTransition: JiraTransition?

    private var isBusy: Bool { store.busyKeys.contains(issue.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isShowingSampleData {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("SAMPLE DATA").font(.system(size: 10, weight: .bold))
                    Text("not your Jira.").font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Color.yellow)
            }
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.actionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if showMetadata { metadata }

                    if showDescription {
                        if let html = issue.descriptionHTML {
                            DescriptionWebView(html: html,
                                               isDark: colorScheme == .dark,
                                               contentHeight: $descriptionHeight)
                                .frame(height: descriptionHeight)
                        } else {
                            Text("This issue has no description.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if showComments { commentsSection }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 340)

        }
        .task(id: issue.key) {
            stagedTransition = nil
            await store.loadTransitions(for: issue.key)
        }
        .task(id: issue.key) {
            guard showComments else { return }
            await store.loadComments(for: issue.key)
        }
    }

    /// The title is the header. The issue key used to sit here and the title below it, which put
    /// a reference number in the most prominent slot on screen and pushed the thing you actually
    /// read down a line. The key is still one click away through the browser link.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the list")

            // The title hugs its text so the platform pill sits against it. It used to stretch to
            // fill the row, which pushed the pill across the header and made it read as belonging
            // to the buttons on the right rather than to the title.
            Text(issue.cleanSummary)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if let platform = issue.platform {
                PlatformPill(platform: platform)
                    // Centre the capsule on the title's first line. Left to the default the pill
                    // hangs low, because its own baseline sits inside its vertical padding.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }

            Spacer(minLength: 6)

            moveMenu

            if let url = store.browseURL(for: issue.key) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .help("Open \(issue.key) in browser")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusPill(name: issue.statusName,
                           categoryKey: issue.fields.status?.statusCategory?.key)
                if let type = issue.fields.issuetype?.name {
                    MetaChip(text: type)
                }
                if let priority = issue.fields.priority?.name {
                    MetaChip(text: priority)
                }
                DueBadge(due: issue.dueDate)
            }
            if let parent = issue.fields.parent {
                Text("Parent: \(parent.key) \(parent.fields?.summary ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let updated = issue.updatedDate {
                Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The discussion. A thread is legitimately longer than a description, so it gets more room
    /// before it starts scrolling inside itself.
    @ViewBuilder
    private var commentsSection: some View {
        let comments = store.commentsByKey[issue.key]

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Comments")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let comments, !comments.isEmpty {
                    Text("\(comments.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 0)
                if store.loadingComments.contains(issue.key) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }

            CommentComposer(store: store, issueKey: issue.key)
                // Breathing room before the thread starts, so the composer reads as its own
                // thing rather than as part of the first comment under it.
                .padding(.bottom, 10)

            if let comments {
                if comments.isEmpty {
                    Text("No comments yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DescriptionWebView(html: JiraComment.composedHTML(
                                            comments,
                                            editableIDs: store.editableCommentIDs(for: issue.key),
                                            reactions: store.reactionsByComment),
                                       isDark: colorScheme == .dark,
                                       onEditComment: { id in
                                           store.beginCommentEdit(id, on: issue.key)
                                       },
                                       onToggleReaction: { id, emojiId in
                                           Task { await store.toggleReaction(emojiId, commentID: id, on: issue.key) }
                                       },
                                       onPickReaction: { id in
                                           store.pickingReactionFor = id
                                       },
                                       contentHeight: $commentsHeight)
                        .frame(height: commentsHeight)

                    if let picking = store.pickingReactionFor {
                        reactionPicker(for: picking)
                    }
                }
            }
        }
    }

    /// A short palette rather than the system emoji panel: the panel cannot be anchored to a
    /// link inside a web view, and eight reactions is what a tracker actually sees used.
    private func reactionPicker(for commentID: String) -> some View {
        HStack(spacing: 4) {
            ForEach(JiraReaction.palette, id: \.self) { emoji in
                Button(emoji) {
                    if let id = JiraReaction.emojiId(for: emoji) {
                        Task { await store.toggleReaction(id, commentID: commentID, on: issue.key) }
                    }
                    store.pickingReactionFor = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 15))
            }
            Spacer(minLength: 0)
            Button {
                store.pickingReactionFor = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
    }

    /// Moving the issue, as one compact control in the header.
    ///
    /// It used to be a Done button beside a "Move to..." menu in a bar along the bottom. The menu
    /// applied its choice the instant it was picked while Done was a separate action that happened
    /// to duplicate one of the menu's entries, so it read as "choose a target, then press Done to
    /// confirm", which is not what it did. One menu, one meaning: what you pick is what happens.
    @ViewBuilder
    private var moveMenu: some View {
        if isBusy {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16)
        } else if !transitions.isEmpty {
            Menu {
                Section("Move from \(issue.statusName) to") {
                    ForEach(transitions) { transition in
                        Button(transition.name) {
                            Task { await store.apply(transition, to: issue.key) }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to another column")
            .accessibilityLabel("Move this issue to another column")
        }
    }

    /// Every move the workflow allows right now, Done included. The server decides what is in
    /// this list, so a workflow change needs no change here.
    private var transitions: [JiraTransition] { store.transitionsByKey[issue.key] ?? [] }

}

struct MetaChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
