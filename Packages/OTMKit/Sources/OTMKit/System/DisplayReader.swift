import AppKit
import CoreGraphics

/// Connected displays from AppKit and Core Graphics, the main one first.
/// Shared by the System page and `otm system report`. It needs the window
/// server, so a shell without a login session (ssh) finds none.
@MainActor
public enum DisplayReader {
    public static func read() -> [DisplayInfo] {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = screen.backingScaleFactor
            let points = screen.frame.size
            let modeRate = mode?.refreshRate ?? 0
            let rate = modeRate > 0 ? modeRate : screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : nil
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                pixelWidth: mode?.pixelWidth ?? Int(points.width * scale),
                pixelHeight: mode?.pixelHeight ?? Int(points.height * scale),
                pointWidth: mode?.width ?? Int(points.width),
                pointHeight: mode?.height ?? Int(points.height),
                scale: Double(scale),
                refreshRate: rate,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
        return displays.filter(\.isMain) + displays.filter { !$0.isMain }
    }
}
