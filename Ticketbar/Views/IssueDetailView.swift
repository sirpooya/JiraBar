import SwiftUI

struct IssueDetailView: View {
    let issue: JiraIssue
    @Bindable var store: IssueStore
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Keys.showDescription) private var showDescription = true
    @AppStorage(Keys.showComments) private var showComments = true
    @State private var descriptionHeight: CGFloat = 60
    @State private var commentsHeight: CGFloat = 40

    private var transitions: [JiraTransition] { store.transitionsByKey[issue.key] ?? [] }
    private var isBusy: Bool { store.busyKeys.contains(issue.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.cleanSummary)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    metadata

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

            Divider().opacity(0.5)
            actions
        }
        .task(id: issue.key) {
            await store.loadTransitions(for: issue.key)
        }
        .task(id: issue.key) {
            guard showComments else { return }
            await store.loadComments(for: issue.key)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the list")

            Text(issue.key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))

            if let platform = issue.platform {
                PlatformPill(platform: platform)
            }

            Spacer()

            if let url = store.browseURL(for: issue.key) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .help("Open in browser")
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
            Divider().opacity(0.5)

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

            if let comments {
                if comments.isEmpty {
                    Text("No comments yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DescriptionWebView(html: JiraComment.composedHTML(comments),
                                       isDark: colorScheme == .dark,
                                       maxHeight: 320,
                                       contentHeight: $commentsHeight)
                        .frame(height: commentsHeight)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if let error = store.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.markDone(issue.key) }
                } label: {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Done", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy || !hasDoneTransition)

                // Every other transition the workflow allows right now. The list comes from the
                // server, so a scheme change needs no code change here.
                Menu {
                    ForEach(otherTransitions) { transition in
                        Button(transition.name) {
                            Task { await store.apply(transition, to: issue.key) }
                        }
                    }
                } label: {
                    Text(otherTransitions.isEmpty ? "No other moves" : "Move to...")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .disabled(otherTransitions.isEmpty || isBusy)
                .fixedSize()

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var hasDoneTransition: Bool {
        transitions.contains { $0.landsInDone }
    }

    private var otherTransitions: [JiraTransition] {
        transitions.filter { !$0.landsInDone }
    }
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
