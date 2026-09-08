import AppKit
import SwiftUI

struct IssueDetailView: View {
    let issue: JiraIssue
    @Bindable var store: IssueStore
    /// True in the detached window, whose height is the user's and stays put. In the popover the
    /// scroll area is capped instead, because a popover grows to whatever its content asks for.
    let fillsHeight: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Keys.showDescription) private var showDescription = true
    @AppStorage(Keys.showComments) private var showComments = true
    @AppStorage(Keys.showMetadata) private var showMetadata = true
    @State private var descriptionHeight: CGFloat = 60
    @State private var commentsHeight: CGFloat = 40
    /// Where in the thread the reaction chip that asked for the picker sits.
    @State private var pickerAnchor: CGPoint = .zero

    private static let pickerWidth: CGFloat = 232
    /// How far right a two-finger swipe has to travel to count as going back.
    private static let swipeBackThreshold: CGFloat = 40
    /// The strip at the top of the panel the swipe is read in. Generous enough to cover the header
    /// in the popover and in the detached window, where the app's own header sits below the
    /// window's title bar, and small enough to leave a horizontal swipe over a wide table or code
    /// block in the thread alone.
    private static let swipeStripHeight: CGFloat = 120

    @State private var swipeMonitor: Any?
    @State private var swipeBack = SwipeTracker()
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
                            DescriptionWebView(html: store.inliningImages(in: html),
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
            .frame(maxHeight: fillsHeight ? .infinity : 340)

        }
        .onAppear { installSwipeBack() }
        .onDisappear { removeSwipeBack() }
        .task(id: issue.key) {
            stagedTransition = nil
            await store.loadTransitions(for: issue.key)
        }
        .task(id: issue.key) { await store.loadFieldRows(for: issue.key) }
        .task(id: issue.key) {
            guard showDescription, let html = issue.descriptionHTML else { return }
            await store.loadImages(in: html)
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
        HStack(alignment: .center, spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    // A fixed box, so the chevron sits on the same vertical line as the buttons
                    // at the other end of the row whatever the title does.
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the list")

            // The title hugs its text so the platform pill sits against it. It used to stretch to
            // fill the row, which pushed the pill across the header and made it read as belonging
            // to the buttons on the right rather than to the title.
            Text(issue.cleanSummary)
                .font(.system(size: 13, weight: .semibold))
                // One line, ending in an ellipsis. Two lines pushed the header taller than the
                // row it shares with the buttons and left the second line clipped in half.
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(issue.cleanSummary)

            if let platform = issue.platform {
                PlatformPill(platform: platform)
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
                    JiraIconChip(assetName: JiraIconAsset.name(forIconURL: issue.fields.issuetype?.iconUrl,
                                                               kind: .issueType),
                                 text: type)
                }
                if let priority = issue.fields.priority?.name {
                    JiraIconChip(assetName: JiraIconAsset.name(forIconURL: issue.fields.priority?.iconUrl,
                                                               kind: .priority),
                                 text: priority)
                }
                DueBadge(due: issue.dueDate)
            }
            if let parent = issue.fields.parent {
                Text("Parent: \(parent.key) \(parent.fields?.summary ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The fields Jira shows down the side of an issue. Only the ones this issue actually
            // has: an empty Component/s or no story points is a row that says nothing.
            ForEach(store.fieldRowsByKey[issue.key] ?? [], id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 96, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    let thread = JiraComment.composedHTML(
                        comments,
                        editableIDs: store.editableCommentIDs(for: issue.key),
                        reactions: store.reactionsByComment)

                    DescriptionWebView(html: store.inliningImages(in: thread),
                                       isDark: colorScheme == .dark,
                                       onEditComment: { id in
                                           store.beginCommentEdit(id, on: issue.key)
                                       },
                                       onToggleReaction: { id, emojiId in
                                           Task { await store.toggleReaction(emojiId, commentID: id, on: issue.key) }
                                       },
                                       onPickReaction: { id in
                                           // No position came with it, so the picker opens at the
                                           // top of the thread rather than nowhere.
                                           store.pickingReactionFor = id
                                           pickerAnchor = .zero
                                       },
                                       onPickReactionAt: { id, point in
                                           store.pickingReactionFor = id
                                           pickerAnchor = point
                                       },
                                       contentHeight: $commentsHeight)
                        .frame(height: commentsHeight)
                        // Floating over the thread, against the chip that asked for it, the way
                        // Jira does it. It used to be appended after the whole thread, which on
                        // anything but a short one put it far below the fold: clicking the chip
                        // looked like it did nothing at all.
                        .overlay(alignment: .topLeading) {
                            if let picking = store.pickingReactionFor {
                                GeometryReader { proxy in
                                    reactionPicker(for: picking)
                                        .frame(width: Self.pickerWidth)
                                        .offset(x: clamp(pickerAnchor.x - 6,
                                                         upTo: proxy.size.width - Self.pickerWidth),
                                                y: clamp(pickerAnchor.y + 4,
                                                         upTo: proxy.size.height - 30))
                                }
                            }
                        }
                }
            }
        }
    }

    /// A short palette rather than the system emoji panel: the panel cannot be anchored to a
    /// link inside a web view, and eight reactions is what a tracker actually sees used.
    // MARK: - Swipe back

    /// A two-finger swipe to the right across the header goes back to the column, the way a swipe
    /// back works elsewhere on the Mac.
    ///
    /// Read from a local scroll monitor rather than a SwiftUI gesture: `DragGesture` is a click and
    /// drag, and a trackpad swipe arrives as a scroll event with precise deltas and a phase, which
    /// no SwiftUI gesture reports.
    private func installSwipeBack() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleSwipeBack(event) ? nil : event
        }
    }

    private func removeSwipeBack() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    /// Never consumes the event: the thread underneath still has to scroll, and the swipe only
    /// acts once it has finished. Whether it counts is judged from the whole gesture's travel,
    /// because the `.began` and `.ended` events carry no deltas at all. See `SwipeTracker`.
    private func handleSwipeBack(_ event: NSEvent) -> Bool {
        guard let contentHeight = event.window?.contentView?.bounds.height,
              event.locationInWindow.y > contentHeight - Self.swipeStripHeight else { return false }

        if event.phase.contains(.began) {
            swipeBack.began()
        } else if event.phase.contains(.changed) {
            swipeBack.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if swipeBack.ended(threshold: Self.swipeBackThreshold) == .right { onBack() }
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            if SwipeTracker.direction(ofUnphasedDeltaX: event.scrollingDeltaX,
                                      deltaY: event.scrollingDeltaY,
                                      threshold: Self.swipeBackThreshold) == .right {
                onBack()
            }
        }
        return false
    }

    /// Keeps the picker inside the thread's own box, whichever chip was clicked.
    private func clamp(_ value: CGFloat, upTo limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        return min(max(0, value), limit)
    }

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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
                        Button(label(for: transition)) {
                            Task { await store.apply(transition, to: issue.key) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to another column")
            .accessibilityLabel("Move this issue to another column")
        }
    }

    /// A destination reads as the board column it lands in, named exactly as Jira names it.
    ///
    /// The column name, not the transition's own name: the dropdown at the top of the panel says
    /// "Testing" where this workflow's transition says "Test", and two names for one place is one
    /// too many. The transition's wording is the fallback for a status no column gathers.
    ///
    /// Nothing is added to the name. An earlier version put an emoji in front of every entry,
    /// which meant two glyphs on the columns already named with one, and an invented glyph on
    /// the columns that are not.
    private func label(for transition: JiraTransition) -> String {
        BoardColumn.name(forStatusID: transition.to?.id, in: store.columns)
            ?? transition.to?.name
            ?? transition.name
    }

    /// Every move the workflow allows right now, Done included. The server decides what is in
    /// this list, so a workflow change needs no change here.
    private var transitions: [JiraTransition] { store.transitionsByKey[issue.key] ?? [] }

}

/// A chip that leads with Jira's own icon for the thing it names, and falls back to the plain
/// text chip when that icon is not one of the bundled ones.
struct JiraIconChip: View {
    let assetName: String?
    let text: String

    var body: some View {
        if let assetName, NSImage(named: assetName) != nil {
            HStack(spacing: 4) {
                Image(assetName)
                    .resizable()
                    .frame(width: 12, height: 12)
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            MetaChip(text: text)
        }
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
