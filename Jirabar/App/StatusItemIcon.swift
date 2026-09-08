import AppKit

/// The menu bar icon: a ticket glyph, plus the count of open issues when there is one.
///
/// Two rendering modes, one rule (see the `menubar-icon-theming` skill):
/// - Template: AppKit throws away RGB and keeps alpha, then tints to match the bar.
/// - Color: every color here is literal, so this code owns all the contrast.
///
/// Nothing is drawn in a hardcoded dark color. The colors are resolved against the appearance
/// that is current *at draw time*, inside `NSImage(size:flipped:drawingHandler:)`, which re-runs
/// per menu bar. That is what makes the icon correct on two displays with opposite wallpapers,
/// where a single probe of `button.effectiveAppearance` can only ever be right about one of them.
enum StatusItemIcon {

    /// What the color mode is allowed to say. Colour carries information here, which is the whole
    /// argument for having a color mode at all.
    enum Urgency {
        case idle       // nothing assigned
        case normal
        case dueToday
        case overdue

        func color(isDark: Bool) -> NSColor {
            switch self {
            case .idle:
                // Not a hardcoded gray: the label color for the bar being drawn, held back a
                // little so an empty queue reads as quiet rather than as an alert.
                return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.55)
            case .normal:
                return isDark ? NSColor(srgbRed: 0.30, green: 0.64, blue: 1.00, alpha: 1)
                              : NSColor(srgbRed: 0.04, green: 0.40, blue: 0.76, alpha: 1)
            case .dueToday:
                return isDark ? NSColor(srgbRed: 1.00, green: 0.65, blue: 0.30, alpha: 1)
                              : NSColor(srgbRed: 0.76, green: 0.37, blue: 0.00, alpha: 1)
            case .overdue:
                return isDark ? NSColor(srgbRed: 1.00, green: 0.42, blue: 0.37, alpha: 1)
                              : NSColor(srgbRed: 0.75, green: 0.22, blue: 0.17, alpha: 1)
            }
        }

        /// Derived from the issues themselves so the color is never decorative.
        static func from(_ issues: [JiraIssue], now: Date = Date()) -> Urgency {
            guard !issues.isEmpty else { return .idle }
            let calendar = Calendar.current
            var dueToday = false
            for issue in issues {
                guard let due = issue.dueDate else { continue }
                if calendar.startOfDay(for: due) < calendar.startOfDay(for: now) { return .overdue }
                if calendar.isDate(due, inSameDayAs: now) { dueToday = true }
            }
            return dueToday ? .dueToday : .normal
        }
    }

    // Menu bar icons are 18pt tall inside a 22pt bar.
    private static let height: CGFloat = 18
    private static let glyphSize = NSSize(width: 15, height: 11)
    private static let gap: CGFloat = 3
    private static func countFont() -> NSFont { .systemFont(ofSize: 11, weight: .semibold) }

    /// - Parameters:
    ///   - monochrome: the single user-facing switch. On means adaptive template rendering and no
    ///     status colors at all.
    static func image(count: Int, urgency: Urgency, monochrome: Bool, showCount: Bool) -> NSImage {
        let text = (showCount && count > 0) ? String(count) : nil
        let size = intrinsicSize(for: text)

        if monochrome {
            // Alpha is all that ships, so there is no point picking colors here.
            let image = render(text: text, size: size, color: .black)
            image.isTemplate = true
            return image
        }

        let dynamic = NSImage(size: size, flipped: false) { rect in
            // Swift spelling is currentDrawing(); this is the appearance of the bar being drawn,
            // which is the only appearance that matters.
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            render(text: text, size: size, color: urgency.color(isDark: isDark))
                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        dynamic.isTemplate = false
        return dynamic
    }

    static func intrinsicSize(for text: String?) -> NSSize {
        var width = glyphSize.width
        if let text {
            width += gap + ceil(text.size(withAttributes: [.font: countFont()]).width)
        }
        return NSSize(width: ceil(width), height: height)
    }

    /// One drawing routine for both modes. Everything it draws uses `color`, so there is no path
    /// where a literal black glyph survives into color mode.
    private static func render(text: String?, size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let glyphRect = NSRect(x: 0,
                               y: ((size.height - glyphSize.height) / 2).rounded(),
                               width: glyphSize.width,
                               height: glyphSize.height)
        color.setFill()
        ticketPath(in: glyphRect).fill()

        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: countFont(),
                .foregroundColor: color,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: glyphRect.maxX + gap,
                                  y: ((size.height - textSize.height) / 2).rounded()),
                      withAttributes: attributes)
        }

        image.unlockFocus()
        return image
    }

    /// A ticket: a rounded rectangle with a notch bitten out of each long edge. The notches are
    /// appended as separate subpaths and filled even-odd, so the overlap becomes a hole.
    private static func ticketPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        let radius: CGFloat = 2.1
        for x in [rect.minX, rect.maxX] {
            path.append(NSBezierPath(ovalIn: NSRect(x: x - radius,
                                                    y: rect.midY - radius,
                                                    width: radius * 2,
                                                    height: radius * 2)))
        }
        path.windingRule = .evenOdd
        return path
    }
}
