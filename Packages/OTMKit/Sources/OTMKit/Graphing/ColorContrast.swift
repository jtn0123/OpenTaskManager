import Foundation

/// Contrast maths for the light-mode shades of the data colours. The bright
/// tones that glow on a dark card wash out as text and thin lines on a pale
/// one, so light mode draws them deeper (see `deepened`); a tone too dim for
/// a dark window is drawn lighter there (`brightened`).
public enum ColorContrast {
    /// An sRGB colour with components in 0...1.
    public struct RGB: Sendable, Hashable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// From a 24-bit hex literal: `RGB(0x56B4E9)`.
        public init(_ hex: UInt32) {
            self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }

        /// From "#56B4E9" or "56B4E9"; nil for anything else.
        public init?(hex: String) {
            var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
            if digits.hasPrefix("#") { digits = digits.dropFirst() }
            guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
            self.init(value)
        }

        /// "#56B4E9": each component rounded to 8 bits.
        public var hex: String {
            func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        }

        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)

        /// Every component times `factor`: the same hue and saturation, darker.
        func scaled(_ factor: Double) -> RGB {
            RGB(red: red * factor, green: green * factor, blue: blue * factor)
        }
    }

    /// Relative luminance as WCAG defines it: 0 for black, 1 for white.
    public static func luminance(_ color: RGB) -> Double {
        func linear(_ component: Double) -> Double {
            let value = min(max(component, 0), 1)
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// Contrast ratio between two colours, from 1 (the same) to 21 (black on white).
    public static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Text over a coloured fill: dark ink or light.
    public enum Ink: Sendable, Equatable {
        case dark
        case light
    }

    /// The ink that reads best over all of `backgrounds` (the colours under a
    /// label, such as the top and bottom of the stretch of gradient it
    /// spans): black or white, whichever's lowest contrast across them is
    /// higher. Over one colour that's dark ink from a relative luminance of
    /// about 0.18 up, where the two contrasts cross.
    public static func ink(over backgrounds: [RGB]) -> Ink {
        guard !backgrounds.isEmpty else { return .dark }
        let dark = backgrounds.map { ratio($0, .black) }.min() ?? 1
        let light = backgrounds.map { ratio($0, .white) }.min() ?? 1
        return dark >= light ? .dark : .light
    }

    /// `color` laid over `background` at `opacity`: what the eye sees of a
    /// translucent wash or ink.
    public static func composite(_ color: RGB, opacity: Double, over background: RGB) -> RGB {
        let alpha = min(max(opacity, 0), 1)
        func mix(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
        return RGB(red: mix(color.red, background.red), green: mix(color.green, background.green), blue: mix(color.blue, background.blue))
    }

    /// `color` darkened just enough to reach `minimum` contrast against white.
    /// Every component scales by the same factor, so a teal stays a teal, only
    /// deeper. A colour that already reaches the contrast comes back unchanged.
    public static func deepened(_ color: RGB, toContrast minimum: Double) -> RGB {
        guard ratio(color, .white) < minimum else { return color }
        // Luminance falls steadily with the factor, so bisect for the largest
        // factor that still reaches the contrast.
        var reaches = 0.0
        var misses = 1.0
        for _ in 0..<24 {
            let factor = (reaches + misses) / 2
            if ratio(color.scaled(factor), .white) >= minimum {
                reaches = factor
            } else {
                misses = factor
            }
        }
        return color.scaled(reaches)
    }

    /// `color` mixed toward white just enough to reach `minimum` contrast
    /// against a dark `background`: the dark-mode counterpart of `deepened`,
    /// for a line that has to stand out on a dark window. A colour that
    /// already reaches the contrast comes back unchanged.
    public static func brightened(_ color: RGB, toContrast minimum: Double, against background: RGB) -> RGB {
        guard ratio(color, background) < minimum else { return color }
        // Over a dark background contrast rises steadily with the white
        // mixed in, so bisect for the least white that reaches it.
        var misses = 0.0
        var reaches = 1.0
        for _ in 0..<24 {
            let share = (misses + reaches) / 2
            if ratio(composite(.white, opacity: share, over: color), background) >= minimum {
                reaches = share
            } else {
                misses = share
            }
        }
        return composite(.white, opacity: reaches, over: color)
    }
}
