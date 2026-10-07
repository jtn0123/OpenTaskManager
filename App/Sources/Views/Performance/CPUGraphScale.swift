import OTMKit
import SwiftUI

/// How the CPU graphs are scaled: fitted to the load on screen (`AutoScale`),
/// or always to the whole CPU, for watching for saturation. One setting,
/// `CPUGraphScale.key`, for every graph that offers it: Performance's CPU
/// graph, its core-type and per-core graphs, CPU by app, and the History
/// page's CPU chart.
enum CPUGraphScale: String, CaseIterable {
    case auto
    case full

    static let key = "cpuGraphScale"
    /// After the top axis label of an auto-scaled graph, so a reader knows
    /// the top isn't 100%.
    static let autoNote = "auto scale"

    /// A CPU axis label: "20%", or "12.5%" for the middle of a 25% scale.
    static func axisLabel(_ fraction: Double) -> String {
        let percent = fraction * 100
        return Format.percent(fraction, digits: abs(percent - percent.rounded()) < 0.01 ? 0 : 1)
    }
}

/// The Auto / 100% choice, for a graph's caption row.
struct CPUScalePicker: View {
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto

    var body: some View {
        Picker("Scale", selection: $scale) {
            Text("Auto").tag(CPUGraphScale.auto)
            Text("100%").tag(CPUGraphScale.full)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Auto fits the CPU graphs to the load on screen, from 10% up; 100% always shows the whole CPU")
    }
}

/// Each auto-scaled graph's `AutoScale`, kept from one sample to the next so
/// its bound holds steady. Not observed: a bound is worked out while the
/// page's body is, once per sample, and changing it mustn't ask for another
/// pass.
@MainActor
final class AutoScaleBounds {
    private var scales: [String: AutoScale] = [:]

    /// The top for `graph`, whose data on screen peaks at `peak`.
    func bound(_ graph: String, peak: Double) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        var scale = scales[graph] ?? AutoScale(peak: peak)
        let bound = scale.update(peak: peak, at: now)
        scales[graph] = scale
        return bound
    }

    /// The highest value a graph of `capacity` samples shows: its last
    /// `capacity + 1` values, as `GraphView` draws them.
    static func peak(_ values: [Double], capacity: Int) -> Double {
        values.suffix(capacity + 1).lazy.filter(\.isFinite).max() ?? 0
    }
}
