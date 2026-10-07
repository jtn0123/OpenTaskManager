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
/// the command line picks a preset for one run.
///
/// Not tied to the main actor, since `Theme`'s colours are read from views'
/// helpers that aren't either; a lock guards the resolved colours.
final class GraphColors: Observable, Sendable {
    typealias Role = GraphPalette.Role
    typealias RGB = ColorContrast.RGB

    static let shared = GraphColors()

    static let presetKey = "graphPalette"

    static func overrideKey(_ role: Role) -> String {
        "graphColor.\(role.rawValue)"
    }

    /// A change's colours, made once.
    private struct Resolved: Sendable {
        var preset = GraphPalette.Preset.standard
        var overrides: [Role: RGB] = [:]
        var palette = GraphPalette.preset(.standard)
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
        UserDefaults.standard.set(preset.rawValue, forKey: Self.presetKey)
        reload()
    }

    /// Sets a resource's own tone, or with nil goes back to the preset's.
    @MainActor func setOverride(_ tone: RGB?, for role: Role) {
        if let tone {
            UserDefaults.standard.set(tone.hex, forKey: Self.overrideKey(role))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey(role))
        }
        reload()
    }

    /// The standard preset, with no colours of the user's own.
    @MainActor func reset() {
        UserDefaults.standard.removeObject(forKey: Self.presetKey)
        for role in Role.resources {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey(role))
        }
        reload()
    }

    /// Reads the settings again and, if they changed, resolves their colours
    /// and tells the views that read them.
    private func reload() {
        let defaults = UserDefaults.standard
        let preset = defaults.string(forKey: Self.presetKey).flatMap(GraphPalette.Preset.init(rawValue:)) ?? .standard
        var overrides: [Role: RGB] = [:]
        for role in Role.resources {
            if let tone = defaults.string(forKey: Self.overrideKey(role)).flatMap(RGB.init(hex:)) {
                overrides[role] = tone
            }
        }
        let current = resolved.withLock { (preset: $0.preset, overrides: $0.overrides, made: !$0.colors.isEmpty) }
        guard !current.made || current.preset != preset || current.overrides != overrides else { return }

        let palette = GraphPalette.preset(preset).overriding(overrides)
        var next = Resolved(preset: preset, overrides: overrides, palette: palette)
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
