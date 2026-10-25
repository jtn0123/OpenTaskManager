import Foundation

/// Björn Ottosson's OKLab, a perceptual colour space, for the palette maths
/// that has to keep lightness or hue as the eye sees them: lightness steps
/// evenly, and a colour's chroma (how vivid it is) can grow at a fixed
/// lightness and hue.
enum PerceptualColor {
    typealias RGB = ColorContrast.RGB

    /// Lightness, then the green–red and blue–yellow axes.
    struct Lab {
        var lightness: Double
        var a: Double
        var b: Double

        var chroma: Double { (a * a + b * b).squareRoot() }
    }

    static func lab(_ color: RGB) -> Lab {
        func linear(_ component: Double) -> Double {
            let value = min(max(component, 0), 1)
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = (linear(color.red), linear(color.green), linear(color.blue))
        // The cone responses, long, medium and short, compressed.
        let long = cbrt(0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue)
        let medium = cbrt(0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue)
        let short = cbrt(0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue)
        return Lab(lightness: 0.210_454_255_3 * long + 0.793_617_785_0 * medium - 0.004_072_046_8 * short,
                   a: 1.977_998_495_1 * long - 2.428_592_205_0 * medium + 0.450_593_709_9 * short,
                   b: 0.025_904_037_1 * long + 0.782_771_766_2 * medium - 0.808_675_766_0 * short)
    }

    /// The sRGB colour at `lab`, or nil where it falls outside sRGB.
    static func rgb(_ lab: Lab) -> RGB? {
        let long = pow(lab.lightness + 0.396_337_777_4 * lab.a + 0.215_803_757_3 * lab.b, 3)
        let medium = pow(lab.lightness - 0.105_561_345_8 * lab.a - 0.063_854_172_8 * lab.b, 3)
        let short = pow(lab.lightness - 0.089_484_177_5 * lab.a - 1.291_485_548_0 * lab.b, 3)
        let linear = [4.076_741_662_1 * long - 3.307_711_591_3 * medium + 0.230_969_929_2 * short,
                      -1.268_438_004_6 * long + 2.609_757_401_1 * medium - 0.341_319_396_5 * short,
                      -0.004_196_086_3 * long - 0.703_418_614_7 * medium + 1.707_614_701_0 * short]
        let slack = 1e-6
        guard linear.allSatisfy({ $0 >= -slack && $0 <= 1 + slack }) else { return nil }
        let encoded = linear.map { value -> Double in
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return RGB(red: encoded[0], green: encoded[1], blue: encoded[2])
    }

    /// `color` at `lightness`, as vivid as sRGB allows there in its own hue.
    /// A near grey comes back as it was, having no hue to saturate.
    static func mostVivid(_ color: RGB, atLightness lightness: Double) -> RGB {
        let lab = lab(color)
        guard lab.chroma > 0.04 else { return color }
        let (cosine, sine) = (lab.a / lab.chroma, lab.b / lab.chroma)
        func at(_ chroma: Double) -> RGB? {
            rgb(Lab(lightness: lightness, a: chroma * cosine, b: chroma * sine))
        }
        // Inside the gamut up to some chroma and outside past it, so bisect for the edge.
        var inside = 0.0, outside = 0.5
        for _ in 0..<30 {
            let chroma = (inside + outside) / 2
            if at(chroma) != nil { inside = chroma } else { outside = chroma }
        }
        return at(inside) ?? color
    }
}
