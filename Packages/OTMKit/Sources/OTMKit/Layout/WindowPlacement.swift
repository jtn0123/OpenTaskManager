import Foundation

/// Where the main window opens and how big it is, in AppKit screen points
/// (origin at the bottom left). A first window takes a share of the screen
/// it opens on; a saved one comes back where the user left it, moved and
/// shrunk only as far as it takes to fit a screen that's still there.
public enum WindowPlacement {
    /// The window's smallest size, which the content asks for as well.
    public static let minimumSize = CGSize(width: 820, height: 480)
    /// A first window's smallest size: the sidebar beside a page with room
    /// for two columns of cards, and the sidebar's breakpoint well behind it.
    public static let defaultMinimum = CGSize(width: 1180, height: 760)
    /// A first window's largest size; past this, pages only gain margins.
    public static let defaultMaximum = CGSize(width: 1440, height: 940)
    /// A first window's share of the screen's width and height.
    public static let defaultShare = CGSize(width: 0.75, height: 0.8)

    /// A first window on a screen whose usable area is `visible`: its share of
    /// the screen, within `defaultMinimum` and `defaultMaximum` and never larger
    /// than the screen, centred across and a little above the middle, as AppKit
    /// centres windows.
    public static func defaultFrame(in visible: CGRect) -> CGRect {
        let wanted = CGSize(
            width: clamp(visible.width * defaultShare.width, defaultMinimum.width, defaultMaximum.width),
            height: clamp(visible.height * defaultShare.height, defaultMinimum.height, defaultMaximum.height)
        )
        return centred(fitting(wanted, in: visible), in: visible)
    }

    /// The frame the window opens at. With no usable saved frame, the default
    /// on `main`. A saved frame goes back on the screen it mostly covers; if
    /// that screen is gone, its size goes to the middle of `main`. Either way
    /// it's shrunk to fit that screen, never below `minimumSize`, and moved
    /// just enough to lie on it, so its title bar can always be reached.
    /// - Parameters:
    ///   - saved: the frame saved when the window last moved or resized.
    ///   - screens: every screen's usable area (`NSScreen.visibleFrame`).
    ///   - main: the usable area of the screen a new window goes on.
    public static func openingFrame(saved: CGRect?, screens: [CGRect], main: CGRect) -> CGRect {
        guard let saved, saved.width > 0, saved.height > 0 else { return defaultFrame(in: main) }
        let home = screens.map { (screen: $0, area: area($0.intersection(saved))) }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?.screen
        guard let home else { return centred(fitting(saved.size, in: main), in: main) }
        let size = fitting(saved.size, in: home)
        let origin = CGPoint(x: clamp(saved.minX, home.minX, home.maxX - size.width),
                             y: clamp(saved.minY, home.minY, home.maxY - size.height))
        return integral(CGRect(origin: origin, size: size))
    }

    /// A frame as it's saved: "x y width height", in whole points.
    public static func string(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: " ")
    }

    /// A saved or requested frame: "x y width height", the four numbers that
    /// start AppKit's own frame strings too. Nil when there's none, it doesn't
    /// read, or it has no size.
    public static func frame(from string: String?) -> CGRect? {
        guard let fields = string?.split(separator: " "), fields.count >= 4 else { return nil }
        let numbers = fields.prefix(4).compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// `size` shrunk to fit `visible`, but never below `minimumSize`.
    private static func fitting(_ size: CGSize, in visible: CGRect) -> CGSize {
        CGSize(width: max(minimumSize.width, min(size.width, visible.width)),
               height: max(minimumSize.height, min(size.height, visible.height)))
    }

    /// Centred across `visible`, with a third of the spare height above and
    /// two thirds below.
    private static func centred(_ size: CGSize, in visible: CGRect) -> CGRect {
        integral(CGRect(x: visible.minX + (visible.width - size.width) / 2,
                        y: visible.minY + max(0, visible.height - size.height) * 2 / 3,
                        width: size.width, height: size.height))
    }

    private static func integral(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width.rounded(), height: frame.height.rounded())
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// `value` within `low` and `high`; `low` wins when they cross (a window
    /// bigger than its screen keeps its left and bottom edges on it).
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}
