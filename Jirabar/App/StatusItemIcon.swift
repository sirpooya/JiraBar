import AppKit

/// The menu bar icon: the mark, plus the count of open issues when there is one.
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
    private static let glyphSize = NSSize(width: 15, height: 15)

    /// The icon is the glyph and nothing else. It carried the issue count beside it once; the
    /// count belongs in the panel, where there is room to say what it counts, and a number in the
    /// menu bar is a number with no label.
    ///
    /// - Parameters:
    ///   - monochrome: the single user-facing switch. On means adaptive template rendering and no
    ///     status colors at all.
    static func image(urgency: Urgency, monochrome: Bool) -> NSImage {
        let size = intrinsicSize

        if monochrome {
            // Alpha is all that ships, so there is no point picking colors here.
            let image = render(size: size, color: .black)
            image.isTemplate = true
            return image
        }

        let dynamic = NSImage(size: size, flipped: false) { rect in
            // Swift spelling is currentDrawing(); this is the appearance of the bar being drawn,
            // which is the only appearance that matters.
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            render(size: size, color: urgency.color(isDark: isDark))
                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        dynamic.isTemplate = false
        return dynamic
    }

    static var intrinsicSize: NSSize {
        NSSize(width: ceil(glyphSize.width), height: height)
    }

    /// One drawing routine for both modes. Everything it draws uses `color`, so there is no path
    /// where a literal black glyph survives into color mode.
    private static func render(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let glyphRect = NSRect(x: 0,
                               y: ((size.height - glyphSize.height) / 2).rounded(),
                               width: glyphSize.width,
                               height: glyphSize.height)
        if let markImage {
            drawTinted(markImage, in: glyphRect, color: color)
        } else {
            // Fallback only. A missing resource is a silent failure in this project's experience
            // (a misspelled SF Symbol name renders as nothing and the build still succeeds), and a
            // menu bar with no icon at all is the one outcome worth writing extra code to avoid.
            let (leading, trailing) = markPaths(in: glyphRect)
            color.setFill()
            leading.fill()
            color.withAlphaComponent(color.alphaComponent * secondaryAlpha).setFill()
            trailing.fill()
        }

        image.unlockFocus()
        return image
    }

    /// The artwork, cropped to its own ink so the glyph lands where `glyphRect` says it does.
    /// The supplied file carries 4 to 5 transparent pixels of margin, unevenly (5 on the left, 4
    /// on the right), so drawing the canvas as-is both shrinks the mark inside its slot and sits
    /// it half a pixel off centre.
    ///
    /// Loaded by URL rather than `NSImage(named:)` so a rename fails here, where the fallback can
    /// see it, instead of resolving to nil somewhere further along.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data)
        else {
            debugLog("MenuBarIcon.png did not load; falling back to the drawn path")
            return nil
        }
        let cropped = cropToInk(source)
        debugLog("MenuBarIcon.png \(source.pixelsWide)x\(source.pixelsHigh) cropped to "
                 + (cropped.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"))
        return cropped
    }()

    /// stderr, not `print`: `print` to a pipe is block buffered and a short-lived run can lose the
    /// line entirely, which is how an earlier logging attempt in this project produced an empty file.
    private static func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write("[StatusItemIcon] \(message)\n".data(using: .utf8)!)
        #endif
    }

    /// Trims fully transparent rows and columns off the edges.
    private static func cropToInk(_ source: NSBitmapImageRep) -> NSImage? {
        var minX = source.pixelsWide, maxX = -1
        var minY = source.pixelsHigh, maxY = -1
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                guard let alpha = source.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.03 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let ink = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let image = NSImage(size: ink.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // colorAt() counts rows from the top; drawing is bottom-up, so flip the origin.
        let fromTop = CGFloat(source.pixelsHigh) - ink.maxY
        source.draw(in: NSRect(origin: .zero, size: ink.size),
                    from: NSRect(x: ink.minX, y: fromTop, width: ink.width, height: ink.height),
                    operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        image.unlockFocus()
        return image
    }

    /// Recolors the artwork by keeping its alpha and replacing every pixel's color, which is what
    /// lets one grayscale file serve both modes: template throws the color away and tints to the
    /// bar, and color mode needs the whole glyph to carry the urgency color.
    private static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// How far the trailing half is held back from the leading one. This is the whole reason the
    /// two halves are separate paths: the source artwork carries its S-curve in a mesh gradient,
    /// and a menu bar icon cannot. Template mode keeps alpha and throws RGB away, so the only
    /// channel a gradient can live in either mode is alpha, and one flat step in alpha is what
    /// makes the interlock legible at 15pt instead of collapsing into a plain diamond.
    private static let secondaryAlpha: CGFloat = 0.45

    /// The mark: one chevron, and the same chevron rotated a half turn about the centre, so the
    /// two interlock and leave a square hole in the middle.
    ///
    /// Kept as two paths, filled at two alphas. They abut along the S-curve, and the antialiased
    /// edges sum there to a value between the two fills rather than to a gap, so the join reads as
    /// a boundary and not as a seam. Merging them into one path would be crisper but would erase
    /// the interlock, which is the only thing distinguishing this glyph from a notched diamond.
    private static let markUnitPaths: (leading: NSBezierPath, trailing: NSBezierPath) = (
        chevronPath(transform: AffineTransform(m11: 1, m12: 0, m21: 0, m22: 1,
                                               tX: 8.759064, tY: 1.930847)),
        chevronPath(transform: AffineTransform(m11: -1, m12: 0, m21: 0, m22: -1,
                                               tX: 15.759062, tY: 21.930908))
    )

    /// The union, so both halves take the *same* fit transform. Measuring them separately would
    /// scale and centre each one to its own bounds and pull the interlock apart.
    private static let markUnitBounds: NSRect =
        markUnitPaths.leading.bounds.union(markUnitPaths.trailing.bounds)

    private static func chevronPath(transform: AffineTransform) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 4.291378, y: 19.166071))
        p.line(to: NSPoint(x: 12.769465, y: 10.559821))
        p.curve(to: NSPoint(x: 13.0, y: 9.997768),
                controlPoint1: NSPoint(x: 12.842518, y: 10.486206),
                controlPoint2: NSPoint(x: 12.900497, y: 10.398644))
        p.curve(to: NSPoint(x: 12.769465, y: 9.435715),
                controlPoint1: NSPoint(x: 13.0, y: 9.893277),
                controlPoint2: NSPoint(x: 12.900497, y: 9.596890))
        p.line(to: NSPoint(x: 9.950472, y: 6.578570))
        p.line(to: NSPoint(x: 9.851083, y: 6.478572))
        p.line(to: NSPoint(x: 3.469868, y: 0.0))
        p.line(to: NSPoint(x: 0.0, y: 3.521429))
        p.line(to: NSPoint(x: 3.469868, y: 7.042857))
        p.line(to: NSPoint(x: 6.382095, y: 10.0))
        p.line(to: NSPoint(x: 3.469868, y: 12.957144))
        p.curve(to: NSPoint(x: 2.033272, y: 16.462097),
                controlPoint1: NSPoint(x: 2.553699, y: 13.886949),
                controlPoint2: NSPoint(x: 2.037227, y: 15.147010))
        p.curve(to: NSPoint(x: 3.469868, y: 20.0),
                controlPoint1: NSPoint(x: 2.029317, y: 17.777185),
                controlPoint2: NSPoint(x: 2.559309, y: 19.064533))
        p.close()
        p.transform(using: transform)
        return p
    }

    /// Scales both halves to sit inside `rect`, aspect preserved and centred. The source bounds
    /// are measured rather than assumed: the artwork does not fill its own 24pt box to the edge,
    /// and hardcoding 24 would inset the glyph by a stray point on every side.
    private static func markPaths(in rect: NSRect) -> (leading: NSBezierPath, trailing: NSBezierPath) {
        let bounds = markUnitBounds
        guard bounds.width > 0, bounds.height > 0 else { return markUnitPaths }

        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let drawn = NSSize(width: bounds.width * scale, height: bounds.height * scale)

        var transform = AffineTransform()
        transform.translate(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
        transform.scale(x: scale, y: scale)
        transform.translate(x: -bounds.minX, y: -bounds.minY)

        func fitted(_ path: NSBezierPath) -> NSBezierPath {
            let copy = path.copy() as! NSBezierPath
            copy.transform(using: transform)
            return copy
        }
        return (fitted(markUnitPaths.leading), fitted(markUnitPaths.trailing))
    }
}
