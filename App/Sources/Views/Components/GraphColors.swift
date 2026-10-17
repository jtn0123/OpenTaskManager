import AppKit
import Observation
import os
import OTMKit
import SwiftUI

/// The graph colours in use: the preset picked in Settings, with the user's
/// own colour for any resource, resolved once per change into the colours
/// `Theme` hands out. A view that reads one observes this, so a change in
/// Settings redraws the graphs at once, without a relaunch; a tick only
/// looks colours up. Kept in UserDefaults under `graphPalette` and
/// `graphColor.<resource>` (a hex string), so `-graphPalette colorBlind` on
/// the command line picks a preset for one run. The retro display look
/// (`RetroDisplay`, `-retroDisplayStyle dotMatrix`) puts its own one-colour
/// palette in place of the preset while it's on.
///
/// Not tied to the main actor, since `Theme`'s colours are read from views'
/// helpers that aren't either; a lock guards the resolved colours.
final class GraphColors: Observable, Sendable {
    typealias Role = GraphPalette.Role
    typealias RGB = ColorContrast.RGB

    static let shared = GraphColors()

    /// A change's colours, made once.
    private struct Resolved: Sendable {
        var preset = GraphPalette.Preset.standard
        var overrides: [Role: RGB] = [:]
        var retro = RetroDisplay(style: .off, tint: .green, glow: .soft)
        var palette = GraphPalette.preset(.standard)
        var readout = NSColor.labelColor
        var colors: [Role: Color] = [:]
        var fills: [Role: NSColor] = [:]
        var series: [Color] = []
        var revision = 0
    }

    private let registrar = ObservationRegistrar()
    private let resolved = OSAllocatedUnfairLock(initialState: Resolved())

    private init() {
        reload()
    }

    // MARK: Reading

    /// Goes up with each change: what AppKit views that cache colours compare.
    var revision: Int {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.revision }
    }

    var preset: GraphPalette.Preset {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.preset }
    }

    /// The user's own tones, by resource.
    var overrides: [Role: RGB] {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.overrides }
    }

    var palette: GraphPalette {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.palette }
    }

    /// The retro display look; its style is `.off` for the usual graphs.
    var retro: RetroDisplay {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.retro }
    }

    /// What a retro display's figures light up in when they have no colour
    /// of their own, for whichever appearance draws them. Not observed:
    /// numbers restyle when `retro` changes.
    var readoutColor: NSColor {
        resolved.withLock { $0.readout }
    }

    /// What controls, links and titles light up in under the retro look,
    /// or nil for the system's.
    var retroAccent: Color? {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.retro.isOn ? Color(nsColor: $0.readout) : nil }
    }

    /// A trace of the retro tint over the window behind the pages, so it
    /// reads as the display's glass; clear with the look off.
    var retroWash: Color {
        registrar.access(self, keyPath: \.revision)
        let retro = resolved.withLock { $0.retro }
        guard retro.isOn else { return .clear }
        let tone = Self.nsColor(retro.tint.tone)
        return Color(nsColor: NSColor(name: nil) { appearance in
            tone.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.06 : 0.04)
        })
    }

    /// How much the lines outweigh the grid and fills, for the palette in use.
    var emphasis: GraphEmphasis {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.palette.emphasis }
    }

    /// A role's colour: its light-mode shade in light mode, its tone in dark.
    func color(_ role: Role) -> Color {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.colors[role] } ?? .gray
    }

    /// A role's fill shade, for AppKit views that draw it behind text. Not
    /// observed: those views compare `revision` themselves.
    func fill(_ role: Role) -> NSColor {
        resolved.withLock { $0.fills[role] } ?? .gray
    }

    /// The `index`th "by app" series colour, round the palette's.
    func seriesColor(_ index: Int) -> Color {
        registrar.access(self, keyPath: \.revision)
        return resolved.withLock { $0.series.isEmpty ? .gray : $0.series[index % $0.series.count] }
    }

    var seriesCount: Int {
        resolved.withLock { max($0.series.count, 1) }
    }

    // MARK: Changing

    @MainActor func select(_ preset: GraphPalette.Preset) {
        Settings.graphPalette.set(preset)
        reload()
    }

    /// Sets a resource's own tone, or with nil goes back to the preset's.
    @MainActor func setOverride(_ tone: RGB?, for role: Role) {
        guard let key = Settings.graphColorOverrides[role] else { return }
        key.set(tone?.hex)
        reload()
    }

    @MainActor func setRetro(_ retro: RetroDisplay) {
        Settings.retroDisplayStyle.set(retro.style)
        Settings.retroDisplayTint.set(retro.tint)
        Settings.retroDisplayGlow.set(retro.glow)
        reload()
    }

    /// The standard preset, with no colours of the user's own.
    @MainActor func reset() {
        Settings.graphPalette.remove()
        for role in Role.resources {
            Settings.graphColorOverrides[role]?.remove()
        }
        reload()
    }

    /// Reads the settings again and, if they changed, resolves their colours
    /// and tells the views that read them.
    private func reload() {
        let preset = Settings.graphPalette.get()
        var overrides: [Role: RGB] = [:]
        for role in Role.resources {
            if let tone = Settings.graphColorOverrides[role]?.get().flatMap(RGB.init(hex:)) {
                overrides[role] = tone
            }
        }
        let retro = RetroDisplay(style: Settings.retroDisplayStyle.get(), tint: Settings.retroDisplayTint.get(),
                                 glow: Settings.retroDisplayGlow.get())
        let current = resolved.withLock { (preset: $0.preset, overrides: $0.overrides, retro: $0.retro, made: !$0.colors.isEmpty) }
        guard !current.made || current.preset != preset || current.overrides != overrides || current.retro != retro else { return }

        // The retro palette is one colour throughout, so a user's own
        // colours wait, kept, until it's off.
        let palette = retro.isOn ? GraphPalette.retro(retro.tint) : GraphPalette.preset(preset).overriding(overrides)
        var next = Resolved(preset: preset, overrides: overrides, retro: retro, palette: palette,
                            readout: retro.isOn ? Self.color(retro.readout) : .labelColor)
        for role in Role.allCases {
            let swatch = palette[role]
            next.colors[role] = Color(nsColor: Self.color(swatch))
            next.fills[role] = Self.nsColor(swatch.dark)
        }
        next.series = palette.series.map { Color(nsColor: Self.color($0)) }
        let made = next
        registrar.withMutation(of: self, keyPath: \.revision) {
            resolved.withLock { state in
                let revision = state.revision + 1
                state = made
                state.revision = revision
            }
        }
    }

    /// The swatch's light-mode shade in light mode and its tone in dark mode.
    private static func color(_ swatch: GraphPalette.Swatch) -> NSColor {
        let dark = nsColor(swatch.dark)
        let light = nsColor(swatch.light)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension NSColor {
    /// The shade a graph strokes a trace in, for the current drawing
    /// appearance: in light mode as deep as the palette's `GraphEmphasis`
    /// draws its lines, so they outweigh the grid and fills around them; in
    /// dark mode the colour as it is. Opacity carries over.
    var traceShade: NSColor {
        guard NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) != .darkAqua else { return self }
        let emphasis = GraphColors.shared.emphasis
        guard emphasis.lightTrace != 1, let srgb = usingColorSpace(.sRGB) else { return self }
        let trace = emphasis.trace(ColorContrast.RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent))
        return NSColor(srgbRed: trace.red, green: trace.green, blue: trace.blue, alpha: srgb.alphaComponent)
    }
}

extension Color {
    /// `NSColor.traceShade`, in whichever appearance draws it.
    var traceShade: Color {
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var shade = base
            appearance.performAsCurrentDrawingAppearance { shade = base.traceShade }
            return shade
        })
    }
}

extension Theme {
    /// Colours for the apps of a "by app" graph, in order. An app keeps its
    /// colour while it stays in the graph, and tends to have the same one in
    /// each graph (`SeriesSlots`), so a change of rank doesn't recolour the
    /// stack. `graph` keeps each graph's slots apart. Only the list of apps
    /// is compared per tick; slots are worked out when it changes.
    @MainActor static func appColors(for ids: [Int64], in graph: String) -> [Color] {
        let count = GraphColors.shared.seriesCount
        var slots = AppSeriesSlots.graphs[graph] ?? SeriesSlots(count: count)
        if slots.count != count { slots = SeriesSlots(count: count) }
        let assigned = slots.assign(ids, homes: &AppSeriesSlots.homes)
        AppSeriesSlots.graphs[graph] = slots
        return assigned.map(series)
    }
}

/// The session's series slots for "by app" graphs (see `Theme.appColors`).
@MainActor
private enum AppSeriesSlots {
    static var homes = SeriesHomes<Int64>()
    static var graphs: [String: SeriesSlots<Int64>] = [:]
}

extension View {
    /// A link-style button: the system's link, or under the retro look,
    /// plain text in its tint, which a link's own colour would ignore.
    func linkButtonStyle() -> some View {
        modifier(LinkButtonStyle())
    }
}

private struct LinkButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if let accent = GraphColors.shared.retroAccent {
            content.buttonStyle(.plain).foregroundStyle(accent)
        } else {
            content.buttonStyle(.link)
        }
    }
}
