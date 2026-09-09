import AppKit
import SwiftUI

struct PopoverRootView: View {
    @Bindable var store: IssueStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    /// Tears the popover off into a floating window, or puts it back.
    let onToggleDetach: () -> Void
    let isDetached: Bool

    private static let width: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the next column change travels, so the list leaves the way the swipe went.
    @State private var columnGoesForward = true
    /// How far the list is currently dragged, updated as the fingers move.
    @State private var columnDrag: CGFloat = 0
    /// True for the single frame in which a committed swipe swaps the column.
    ///
    /// The swipe has already carried the old list off screen and the placeholder into its place by
    /// then, so the scope change must land silently. Without this the content transition would run
    /// a SECOND slide on top of the one the fingers just finished, which is the double movement
    /// this whole path exists to remove.
    @State private var isCommittingSwipe = false

    /// The panel's own width, so the column a swipe is heading for can be parked exactly one
    /// panel away. Measured rather than assumed: 380 in the popover, but the user's own width
    /// once the panel is detached into a resizable window.
    @State private var panelWidth: CGFloat = 380

    @State private var columnSwipeMonitor: Any?
    @State private var columnSwipe = SwipeTracker()

    private static let columnSwipeThreshold: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if let key = store.selectedKey, let issue = store.issue(for: key) {
                IssueDetailView(issue: issue, store: store, fillsHeight: isDetached) {
                    store.selectedKey = nil
                    store.actionError = nil
                }
                // Opening an issue pushes it in from the trailing edge and takes the list out to
                // the leading one, so the two read as one place you moved through rather than as
                // a swap. Going back runs it the other way, which is the same direction the swipe
                // across the header goes.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // One container, one transition.
                //
                // These six views used to sit loose in the `if`/`else`. That makes every one of
                // them a root of the removal, so `content`'s column-paging transition also fired
                // when an issue was opened, and took the list out whichever way the LAST column
                // swipe happened to have gone. Half the time that was the same edge the detail
                // was arriving from, which is what read as the push running backwards. Wrapped,
                // only the transition below applies and the children travel with it.
                VStack(spacing: 0) {
                    if store.isShowingSampleData { sampleDataBanner }
                    header
                    Divider().opacity(0.5)
                    ZStack {
                        content
                        // Fills the detached window, so the header stays at the top and the footer
                        // at the bottom instead of the whole panel floating in the middle of a
                        // tall window. The list already did this; the loading and empty states
                        // did not.
                        .frame(maxHeight: isDetached ? .infinity : nil)
                        // Follows the fingers while the swipe is happening, so the panel answers
                        // the gesture rather than sitting still and then jumping when it ends.
                        .offset(x: columnDrag)
                        .id(store.scope?.id ?? "no-column")
                        // Changing COLUMN only. Opening an issue is the wrapper's transition
                        // below, and these two must not be confused again.
                        //
                        // What must never come back is `withAnimation` around the scope change:
                        // setting the scope replaces the whole tree at once (the list becomes the
                        // loading state, the header text and the count change), and animating that
                        // transaction told SwiftUI to move every changed view separately, so rows
                        // came apart and avatars and half drawn text flew across the panel.
                        // Attached here, it animates this view's arrival and departure and
                        // nothing else.
                        .transition(.asymmetric(
                            insertion: .move(edge: columnGoesForward ? .trailing : .leading),
                            removal: .move(edge: columnGoesForward ? .leading : .trailing)
                                .combined(with: .opacity)))
                        .animation(reduceMotion || isCommittingSwipe
                                       ? nil : .snappy(duration: 0.28),
                                   value: store.scope?.id)
                        // Skeleton to real rows is a cross fade in place, never another
                        // slide: the slide already happened when the column changed. Keyed to the
                        // loading boundary alone, so a refresh that swaps rows for newer rows
                        // does not animate and cannot revive the flying-avatars bug above.
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                                   value: store.state.isLoading)
                    }
                    // Measured, so the peek below can be parked exactly one panel away whatever
                    // width the detached window has been dragged to.
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { panelWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, width in panelWidth = width }
                        })
                    // An overlay and not another child of the stack: an overlay is sized to what
                    // it covers, so a placeholder taller than the real list cannot stretch the
                    // popover the moment a swipe starts.
                    .overlay { columnPeek }
                    Divider().opacity(0.5)
                    footer
                }
                // The list leaves towards the leading edge while the issue arrives from the
                // trailing one, so the two read as one step deeper rather than as two views
                // crossing. Going back runs the same thing in reverse.
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        // Clipped, or the view sliding out is drawn beyond the panel while it goes.
        .clipped()
        // Short on purpose. In the popover the panel is sized to its content, so this animates the
        // popover's own size as well, and a long one would leave the window stretching visibly.
        // Off entirely when the system asks for less motion.
        .animation(navigationAnimation, value: store.selectedKey)
        // In the popover the size is the content's: a popover has no frame of its own to fill,
        // so the width is pinned and the scroll areas are capped.
        //
        // In the detached window it is the other way round. The window's size is the user's, and
        // the panel fills it in both directions, with 380 as the floor. Pinned to 380 the panel
        // sat in a window dragged out to 572 with a wide empty margin beside it, and navigating
        // between the list and an issue changed nothing about the window, only what was stranded
        // inside it.
        .frame(minWidth: Self.width,
               maxWidth: isDetached ? .infinity : Self.width,
               maxHeight: isDetached ? .infinity : nil)
        .onAppear { installColumnSwipe() }
        .onDisappear { removeColumnSwipe() }
    }

    /// Shown only under `--qc-state=...`. Loud on purpose: fixture issues look exactly like real
    /// ones, and a build accidentally left running with the flag reads as a genuine board.
    private var sampleDataBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("SAMPLE DATA")
                .font(.system(size: 10, weight: .bold))
            Text("not your Jira. Launched with --qc-state.")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.yellow)
    }

    // MARK: - Header

    /// A ZStack, not an HStack: the dropdown is centred on the popover, so it must not be pushed
    /// around by however wide the count pill or the buttons happen to be.
    private var header: some View {
        ZStack {
            scopePicker

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }

                Button(action: onToggleDetach) {
                    // A pin, because it says what detaching is for rather than what it makes: the
                    // panel stays put instead of closing the moment focus moves. Filled while it
                    // is pinned. Not the picture-in-picture pair this started as, which borrowed a
                    // video metaphor for a window.
                    Image(systemName: isDetached ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(isDetached ? "Put it back in the menu bar" : "Detach into a floating window")
                .accessibilityLabel(isDetached ? "Return to the menu bar" : "Detach into a window")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The board's columns, and nothing else. They come from the server, so a board the team
    /// rearranges needs no change here.
    // MARK: - Swiping between columns

    /// A two-finger swipe steps through the board's columns, left for the next one and right for
    /// the previous, which is the same direction sense as the swipe back inside an issue. The ends
    /// hold instead of wrapping.
    ///
    /// Anywhere over the list, not just the header: the header is a 56 point strip at the top of
    /// a panel that is mostly rows, so a swipe aimed at the list did nothing. Scrolling the rows
    /// still works, because a gesture only counts as a swipe when its whole travel is further
    /// sideways than vertical.
    ///
    /// A local scroll monitor for the same reason as the swipe back: a trackpad swipe is a scroll
    /// event with precise deltas and a phase, and no SwiftUI gesture reports it.
    private func installColumnSwipe() {
        guard columnSwipeMonitor == nil else { return }
        columnSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleColumnSwipe(event) ? nil : event
        }
    }

    private func removeColumnSwipe() {
        if let columnSwipeMonitor { NSEvent.removeMonitor(columnSwipeMonitor) }
        columnSwipeMonitor = nil
    }

    /// Never consumes the event: the list underneath still has to scroll normally, and a swipe
    /// only ever adds an action once it has finished.
    private func handleColumnSwipe(_ event: NSEvent) -> Bool {
        // Only over the list. An issue is open on top of this, and a swipe there means go back.
        guard store.selectedKey == nil, store.columns.count > 1 else { return false }

        if event.phase.contains(.began) {
            columnSwipe.began()
            columnDrag = 0
        } else if event.phase.contains(.changed) {
            columnSwipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            columnDrag = liveDrag()
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if let direction = columnSwipe.ended(threshold: Self.columnSwipeThreshold) {
                commit(forward: direction == .left)
            } else {
                // Not far enough. It springs back, which is the gesture being answered with a no.
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { columnDrag = 0 }
            }
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            let direction = SwipeTracker.direction(ofUnphasedDeltaX: event.scrollingDeltaX,
                                                   deltaY: event.scrollingDeltaY,
                                                   threshold: Self.columnSwipeThreshold)
            if let direction { step(forward: direction == .left) }
        }
        return false
    }

    /// Finishes a swipe by carrying it the rest of the way, rather than starting a new animation.
    ///
    /// The release used to set `columnDrag` back to zero and let the content transition slide the
    /// list out from there. That is two movements: the list snapped back the 46 points the fingers
    /// had pulled it, and only then did anything slide, so the new column arrived from nowhere
    /// instead of from the edge the placeholder had been sitting at.
    ///
    /// Here the drag simply continues to a full panel width. The list goes out and the placeholder
    /// that has been travelling beside it comes in, as one motion at the speed the fingers left
    /// off. Only when it lands is the column actually swapped, and by then the placeholder is
    /// already exactly where the new list will be drawn, so the swap itself is invisible.
    private func commit(forward: Bool) {
        guard let next = ColumnPaging.column(after: store.scope,
                                             in: store.columns,
                                             forward: forward) else {
            // Nothing to go to. Same answer as a swipe that was too short.
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { columnDrag = 0 }
            return
        }

        guard !reduceMotion else {
            columnDrag = 0
            select(next)
            return
        }

        let duration = 0.26
        isCommittingSwipe = true
        withAnimation(.snappy(duration: duration)) {
            columnDrag = forward ? -panelWidth : panelWidth
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            // Both of these together, and silently: the placeholder is at offset zero by now, and
            // the list that replaces it is drawn at offset zero too, so nothing moves.
            columnDrag = 0
            select(next)
            // Cleared a turn later, so the scope change above is the one evaluated with the
            // transition suppressed and the next ordinary column change animates normally.
            DispatchQueue.main.async { isCommittingSwipe = false }
        }
    }

    private func step(forward: Bool) {
        guard let next = ColumnPaging.column(after: store.scope,
                                             in: store.columns,
                                             forward: forward) else { return }
        select(next)
    }

    /// Where the list sits mid swipe. It gives way less at an end of the board, because there is
    /// nothing to go to and the panel should say so rather than promising a column that is not
    /// there.
    private func liveDrag() -> CGFloat {
        guard columnSwipe.isSideways else { return 0 }
        let travel = columnSwipe.sidewaysTravel
        let hasSomewhereToGo = ColumnPaging.column(after: store.scope,
                                                   in: store.columns,
                                                   forward: travel < 0) != nil
        return SwipeTracker.rubberBand(travel, limit: hasSomewhereToGo ? 46 : 16)
    }

    /// The column the swipe is heading for, travelling with the fingers.
    ///
    /// Without this a swipe pulled the list aside and uncovered whatever sat behind the panel, so
    /// the gesture read as tearing the panel loose rather than as moving to the column next to it.
    /// `liveDrag` rubber bands the list to at most 46 points, so this is a peek at the edge and
    /// not a page turn.
    ///
    /// It is a skeleton because the column it belongs to has genuinely not been asked for yet:
    /// the fetch starts when the swipe is released. Drawing real rows here would mean fetching
    /// every neighbour on the chance you might swipe to it.
    ///
    /// Nothing here survives the release. `columnDrag` goes back to zero before the scope changes,
    /// so the peek is gone by the time the transition that replaces the list begins, and the two
    /// can never be on screen together.
    @ViewBuilder
    private var columnPeek: some View {
        if columnDrag != 0 {
            // Dragging the list left uncovers the trailing edge, and the column that arrives there
            // is the next one. Dragging right uncovers the leading edge and the previous one.
            let forward = columnDrag < 0
            // Nothing at the ends of the board. `liveDrag` still gives a short rubber band there,
            // and that resistance against an empty edge is the panel saying there is nowhere left
            // to go, which a placeholder would flatly contradict.
            if ColumnPaging.column(after: store.scope,
                                   in: store.columns,
                                   forward: forward) != nil {
                SkeletonListView(rowCount: store.skeletonRowCount, fillsHeight: isDetached)
                    // Exactly one panel away on the side being uncovered, so it comes in at the
                    // same rate the list goes out.
                    .offset(x: columnDrag + (forward ? panelWidth : -panelWidth))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Used by the swipe and by the dropdown alike, so picking "Done" from the menu travels the
    /// same direction as swiping to it.
    ///
    /// Deliberately not wrapped in `withAnimation`: see the comment on the content's transition.
    private func select(_ column: BoardColumn) {
        if let from = store.scope.flatMap({ store.columns.firstIndex(of: $0) }),
           let to = store.columns.firstIndex(of: column) {
            columnGoesForward = to > from
        }
        store.scope = column
    }

    /// Column name, then the count, then the chevron, in that order and inside one control.
    ///
    /// This is why the menu style is `.button` and not `.borderlessButton`. A borderless `Menu`
    /// renders only the FIRST view of a composed label, so every earlier attempt at putting the
    /// badge in here silently dropped either the count or the column name. `.button` renders the
    /// whole label, `.buttonStyle(.plain)` takes the border back off, and `.menuIndicator(.hidden)`
    /// removes the system chevron so ours can sit after the badge instead of before it.
    /// Going back is given longer than going in. At equal durations it reads as faster: the list
    /// is already built and lands instantly, while an issue is still filling in as it arrives.
    private var navigationAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .snappy(duration: store.selectedKey == nil ? 0.32 : 0.22)
    }

    private var scopePicker: some View {
        Menu {
            ForEach(store.columns) { column in
                Button {
                    select(column)
                } label: {
                    Label(column.name, systemImage: store.scope == column ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.scope?.name ?? "Loading board...")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                // Always rendered, invisible at zero, so its slot never changes width.
                //
                // Measured 2026-09-09 off a screen recording of a column switch: `scope.didSet`
                // sets `state = .loading`, the count read zero for the ~150ms the new column took
                // to load, and the badge disappeared. Because this control is centred, losing it
                // narrowed the group and slid the column name 28 points right and then straight
                // back left, with the chevron going the other way.
                //
                // Reserving the slot fixed the sliding but not the blink: the capsule itself
                // still went and came back. So the header reads `displayCount`, which holds the
                // previous number while a column loads, and the badge now stays put and simply
                // changes value. `numericText` rolls the digits rather than cutting between them.
                //
                // `monospacedDigit` plus the min width hold one and two digit counts to the same
                // size, so 6 becoming 23 cannot move the name either. Three digits will still
                // grow it, which is the right trade: a column with a hundred issues is not a
                // case worth padding every other column for.
                Text("\(store.displayCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    // Still hidden when there is genuinely nothing to report, which is a real
                    // answer and not the transient zero the loading state used to produce.
                    .opacity(store.displayCount > 0 ? 1 : 0)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25),
                               value: store.displayCount)

                // Hand-drawn, because the system indicator cannot be moved to the far side of the
                // badge. "chevron.down" is a real symbol name: a misspelled one draws nothing and
                // still builds.
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.columns.isEmpty)
        .help("\(store.displayCount) issues in this column")
        .accessibilityLabel("Showing \(store.scope?.name ?? "no column yet"), \(store.displayCount) issues. Choose a board column.")
    }

    // MARK: - Content

    /// One switch, one case per state. There is no `default`, so a new state cannot quietly
    /// inherit somebody else's view, and no branch here can draw an empty list for a failure.
    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .needsToken:
            NeedsTokenView(onOpenSettings: onOpenSettings)

        case .loading:
            // The shape of the list rather than a spinner on an empty panel, so a column swipe
            // slides in something with structure and only the content changes when it lands.
            SkeletonListView(rowCount: store.skeletonRowCount, fillsHeight: isDetached)
                .transition(.opacity)

        case .issues(let issues):
            IssueListView(issues: issues, store: store, fillsHeight: isDetached)
                .transition(.opacity)

        case .empty:
            EmptyIssuesView(onRefresh: onRefresh)

        case .tokenRejected:
            TokenRejectedView(tokenPageURL: store.tokenPageURL, onOpenSettings: onOpenSettings)

        case .unreachable(let reason):
            UnreachableView(host: store.baseURL?.host ?? "the server",
                            reason: reason,
                            onRetry: onRefresh)

        case .failed(let message):
            GenericFailureView(message: message, onRetry: onRefresh)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let name = store.accountName {
                Text(name).lineLimit(1)
                Text("·")
            }
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not updated yet")
            }
            Spacer(minLength: 4)
            if !isDetached {
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct IssueListView: View {
    let issues: [JiraIssue]
    @Bindable var store: IssueStore
    var fillsHeight = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.actionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.10))
            }

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(issues) { issue in
                        IssueRowView(issue: issue,
                                     store: store,
                                     showsStatus: store.scope?.gathersMultipleStatuses ?? false,
                                     onSelect: {
                                         store.actionError = nil
                                         store.selectedKey = issue.key
                                     })
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }
            // Roughly five rows in the popover, which cannot be allowed to grow past the bottom
            // of the screen. In the detached window the list takes the height the window has.
            .frame(maxHeight: fillsHeight ? .infinity : 380)
        }
    }
}
