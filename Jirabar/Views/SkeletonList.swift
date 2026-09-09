import SwiftUI

/// The shape of the list, drawn before the list exists.
///
/// Swiping to another column used to slide in `LoadingView`, a spinner on an otherwise empty
/// panel, and then replace it with rows the instant the fetch returned. That is three visual steps
/// for one gesture, and in the popover, which sizes to its content, the panel collapsed to the
/// spinner's height in the middle of the swipe and sprang back open afterwards.
///
/// This draws the same two line row at the same paddings as `IssueRowView`, so the incoming column
/// already has its structure while it loads and only the content changes when it lands. Keep the
/// paddings here and in `IssueRowView` the same: the whole point is that a row does not change
/// height when the real one replaces it.
struct SkeletonListView: View {
    /// How many rows to draw. The outgoing column's count is the best guess available for the
    /// incoming one, and using it keeps the popover from changing height mid swipe.
    let rowCount: Int
    var fillsHeight = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<max(rowCount, 1), id: \.self) { index in
                SkeletonRow(titleFraction: Self.titleFractions[index % Self.titleFractions.count])
            }
            if fillsHeight { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity,
               maxHeight: fillsHeight ? .infinity : nil,
               alignment: .top)
        // A slow breath, not a travelling sweep. The swipe is already moving this whole view
        // sideways, and a second moving thing inside it reads as two animations fighting.
        .opacity(dimmed ? 0.55 : 1)
        .animation(reduceMotion ? nil
                                : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                   value: dimmed)
        .onAppear { if !reduceMotion { dimmed = true } }
        // One element, one label. Read row by row it would announce a dozen meaningless bars.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading issues")
    }

    /// Varied so the placeholder reads as titles of different lengths rather than as a barcode.
    private static let titleFractions: [CGFloat] = [0.72, 0.54, 0.83, 0.46, 0.66, 0.60]
}

private struct SkeletonRow: View {
    /// How much of the available width the title bar takes.
    let titleFraction: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // The metadata line: type icon, issue key, one pill.
                HStack(spacing: 6) {
                    bar(width: 12, height: 12, radius: 3)
                    bar(width: 52, height: 11, radius: 3)
                    // 16, matching the capsule pills, because this bar is the tallest thing on
                    // the line and therefore what sets the line's height.
                    bar(width: 44, height: 16, radius: 8)
                    Spacer(minLength: 0)
                }
                // The title line, which is what the eye actually lands on. Measured off the
                // container so it stays proportional at any panel width.
                GeometryReader { proxy in
                    bar(width: proxy.size.width * titleFraction, height: 16, radius: 4)
                }
                .frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Matches `AssigneeAvatar`'s 20 point circle, so the trailing column lines up with
            // the real rows that replace these.
            Circle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 20, height: 20)
        }
        // 9 + 16 + 4 + 16 + 9, plus the stack's 1 point spacing, is a 55 point pitch. Measured
        // 2026-09-09 off a screenshot of the real list, whose rows sit on the same 55. At the
        // first attempt these bars were 4 points shorter and every row below the first crept
        // downwards when the real data replaced them, which is the exact jump this view exists
        // to prevent.
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func bar(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .frame(width: width, height: height)
    }
}
