import AppKit

/// Menu bar icon colours. Thresholds match the popover's progress bars (see
/// `colorForPercentage` in Views/AccountUsageSection.swift) so a glance at the
/// menu bar and a look at the popover never disagree.
func usageColor(percentage: Int) -> NSColor {
    if percentage < 70 {
        return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
    } else if percentage < 90 {
        return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)    // Yellow
    } else {
        return NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)  // Red
    }
}

/// Every coordinate in this file is in this box, which is both the image's size
/// and the space the SVG path was authored in. The drawing handler is handed
/// this same rect — measured, not assumed — so nothing here has to consult it.
private let iconBox = NSSize(width: 16, height: 16)

/// SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
/// `scale` and `offsetY` shrink the spark up into the top-left corner so a
/// badge digit has a clear bottom-right corner to sit in.
private func sparkPath(scale: CGFloat = 1, offsetY: CGFloat = 0) -> NSBezierPath {
    let raw: [(CGFloat, CGFloat)] = [
        (8, 1), (9, 6), (13, 3), (10, 7), (15, 8), (10, 9), (13, 13), (9, 10),
        (8, 15), (7, 10), (3, 13), (6, 9), (1, 8), (6, 7), (3, 3), (7, 6)
    ]
    let path = NSBezierPath()
    for (index, point) in raw.enumerated() {
        let p = NSPoint(x: point.0 * scale, y: point.1 * scale + offsetY)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

// MARK: - Badge
//
// The badge is drawn on the icon's own grid instead of being set in a font.
// A 9-11pt glyph inside a 16pt box is only ever 6-8 device pixels tall on a
// non-Retina display, and none of its edges land on pixel boundaries, so it
// rasterises almost entirely to partial coverage and reads as a smudge next to
// the spark. These cells are whole points, so every pixel of the digit comes
// out fully opaque at 1x and at 2x alike. Measured, both scales, before and
// after: see the task 6 report.
//
// Rows run top-down, which is how they are legible here; the drawing context is
// y-up, so `badgePath` flips them. The glyph literals below are the only
// definition of the grid (5 cells wide by 7 tall): badgePath measures each one
// it is handed, so a new digit added in a different shape draws as written
// rather than being reflowed to fit a constant declared somewhere above.

/// Bottom-left of the glyph box. x leaves a 1pt margin to the icon's right edge
/// so the badge never sits flush against the button title beside it, and y
/// leaves 1pt below so no cell can be clipped away.
private let badgeOrigin = NSPoint(x: 10, y: 1)

private let badgeGlyphs: [Int: [String]] = [
    1: ["..##.",
        ".###.",
        "..##.",
        "..##.",
        "..##.",
        "..##.",
        ".####"],
    2: ["####.",
        "#####",
        "...##",
        "..##.",
        ".##..",
        "##...",
        "#####"]
]

private func badgePath(_ digit: Int) -> NSBezierPath? {
    guard let rows = badgeGlyphs[digit] else { return nil }
    let path = NSBezierPath()
    for (rowIndex, row) in rows.enumerated() {
        let y = badgeOrigin.y + CGFloat(rows.count - 1 - rowIndex)
        for (columnIndex, cell) in row.enumerated() where cell == "#" {
            path.appendRect(NSRect(x: badgeOrigin.x + CGFloat(columnIndex), y: y,
                                   width: 1, height: 1))
        }
    }
    return path
}

/// Shrunk and pinned back to the spark's own top edge (15 in path space), which
/// clears the badge's corner. The binding constraint is the lower-right arm tip
/// at (13·scale, 15 - 12·scale): it runs straight through the digit's band, and
/// two shapes in one colour that touch read as one blob. At 0.68 the tip sits
/// at x = 8.84, leaving a clear pixel column before the badge at 10.
private let badgedSparkScale: CGFloat = 0.68

func menuBarIcon(percentage: Int, badge: Int?) -> NSImage {
    let color = usageColor(percentage: percentage)

    // drawingHandler re-renders at whatever backing scale the icon is drawn at.
    // lockFocus froze one raster at the scale in effect when the image was
    // built, so plugging in a display of a different scale left it resampled —
    // unnoticeable on a flat spark, ugly on a badge.
    let image = NSImage(size: iconBox, flipped: false) { _ in
        color.setFill()

        // One account: the 1.3.x icon, untouched. Same path, same size, no
        // badge — a single user must not be able to tell this task shipped.
        // An unknown slot lands here too: an unnumbered icon beats a blank one.
        guard let badge = badge, let digit = badgePath(badge) else {
            sparkPath().fill()
            return true
        }

        sparkPath(scale: badgedSparkScale,
                  offsetY: 15 * (1 - badgedSparkScale)).fill()
        digit.fill()
        return true
    }
    image.isTemplate = false
    return image
}
