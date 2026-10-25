import Foundation

/// How graphs weigh their lines against what's drawn around them, for a
/// palette (`GraphPalette.emphasis`): traces a little deeper in light mode,
/// and solid ones a little wider, than their colours alone would draw them,
/// the grid and the fills under the lines a little fainter, so the readings
/// come first and the decoration second. What says a stretch wasn't
/// recorded (its wash, hatch and edges) isn't decoration, and keeps its weight.
public struct GraphEmphasis: Sendable, Hashable {
    public typealias RGB = ColorContrast.RGB

    /// A solid trace's width, times this. Dashed and dotted lines, the
    /// second line of a pair, keep theirs, so the first reads first.
    public static let traceWidth = 1.15

    /// Light mode's traces: the colour light mode draws with every component
    /// times this, the same hue deeper. Dark mode draws the colour as it is,
    /// since on a dark window a darker line is a fainter one.
    public var lightTrace: Double
    /// The grid's opacity, times this.
    public var grid: Double
    /// The opacity of the fill under a line, times this.
    public var fill: Double
    /// A stack's bands' opacity, times this: the bands are the readings, so
    /// they fade less than a fill under a line does.
    public var bands: Double

    public init(lightTrace: Double, grid: Double, fill: Double, bands: Double) {
        self.lightTrace = lightTrace
        self.grid = grid
        self.fill = fill
        self.bands = bands
    }

    /// The standard palette's: an eighth deeper, so a trace's contrast on
    /// white goes from 4.5:1 to about 5.5:1.
    public static let standard = GraphEmphasis(lightTrace: 0.88, grid: 0.77, fill: 0.78, bands: 0.9)

    /// The colour-blind palette's light shades sit just far enough apart for
    /// someone without red–green vision, set apart by depth as well as hue;
    /// even a sixteenth deeper crowds a pair of them together, so its traces
    /// keep their shade, and stand out by width and the fainter decoration.
    public static let colorBlind = GraphEmphasis(lightTrace: 1, grid: 0.77, fill: 0.78, bands: 0.9)

    /// High contrast's lines already reach 7:1 or more, and any deeper they'd
    /// lose their hue, so they keep their shade; its grid fades less, for
    /// whoever leans on it to read a value off.
    public static let highContrast = GraphEmphasis(lightTrace: 1, grid: 0.9, fill: 0.78, bands: 0.9)

    /// The light-mode trace of a colour light mode draws as `light`.
    public func trace(_ light: RGB) -> RGB {
        lightTrace == 1 ? light : light.scaled(lightTrace)
    }
}
