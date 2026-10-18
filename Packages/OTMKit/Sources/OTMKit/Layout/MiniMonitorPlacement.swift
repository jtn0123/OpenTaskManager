import CoreGraphics

/// A corner of a screen's usable area (`Settings.miniMonitorCorner`).
public enum ScreenCorner: String, CaseIterable, Sendable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var id: Self { self }

    public var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

/// Where the mini monitor goes: in a corner of a screen's usable area, a
/// margin in from both edges, wherever it was dragged to. Rects are in
/// AppKit's screen points, origin at the bottom left.
public enum MiniMonitorPlacement {
    /// The gap between the panel and the usable area's edges.
    public static let margin: CGFloat = 12

    /// A panel `size` big in `corner` of `visible`. One larger than the
    /// area keeps its size and its corner's edges.
    public static func frame(size: CGSize, corner: ScreenCorner, in visible: CGRect) -> CGRect {
        let x = corner.isLeft ? visible.minX + margin : visible.maxX - margin - size.width
        let y = corner.isTop ? visible.maxY - margin - size.height : visible.minY + margin
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The corner a panel dropped at `frame` goes to: the one on the side of
    /// `visible`'s middle that its own middle is on, across and up.
    public static func corner(nearest frame: CGRect, in visible: CGRect) -> ScreenCorner {
        let left = frame.midX < visible.midX
        let top = frame.midY >= visible.midY
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
