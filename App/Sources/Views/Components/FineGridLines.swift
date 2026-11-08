import AppKit
import OTMKit

/// A main graph's fine grid, as `StreamGraphView` draws it for a
/// `fineRows` configuration: still rows, a firmer line at each quarter
/// where the rows divide by four, and minor columns about as far apart
/// (`FineGridSpacing`), which scroll with the data.
enum FineGridLines {
    /// The rows of a plot `size` big, `inset` from its foot and top, in
    /// `rows` steps: the minor lines, then the quarters'.
    static func rows(size: CGSize, inset: CGFloat, rows: Int) -> (minor: CGPath, major: CGPath) {
        let minor = CGMutablePath()
        let major = CGMutablePath()
        let step = CGFloat(FineGridSpacing.row(height: Double(size.height), inset: Double(inset), rows: rows))
        guard step > 0, size.width > 4 else { return (minor, major) }
        for row in 1..<rows {
            let y = (inset + CGFloat(row) * step).rounded() + 0.25
            let path = rows % 4 == 0 && row % (rows / 4) == 0 ? major : minor
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return (minor, major)
    }

    /// The lines' colours: faint enough that a trace near the floor isn't
    /// lost among them, firmer in light mode to hold up on a pale plot, and
    /// fainter by the palette's `GraphEmphasis`, as the usual grid is.
    static func colors(dark: Bool, emphasis: GraphEmphasis) -> (minor: CGColor, major: CGColor) {
        let weight = CGFloat(emphasis.grid)
        return (NSColor.labelColor.withAlphaComponent((dark ? 0.05 : 0.07) * weight).cgColor,
                NSColor.labelColor.withAlphaComponent((dark ? 0.09 : 0.12) * weight).cgColor)
    }
}
