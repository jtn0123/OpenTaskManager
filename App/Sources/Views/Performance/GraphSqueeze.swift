import AppKit
import OTMKit
import SwiftUI

/// The Squeeze older time toggle (`AppModel.squeezesOlderTime`), in the
/// time axis of a Performance detail's main graph: the graph keeps its
/// window at the right and squeezes older time into the rest of its width
/// (`TimeWarp`), so it covers 15 windows. One setting for every main graph.
struct GraphSqueezeToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let window = Format.timeSpan(Double(AppModel.graphSpan) * model.samplingInterval)
        let whole = Format.timeSpan(Double(AppModel.graphSpan) * TimeWarp.standard.span * model.samplingInterval)
        Toggle("Squeeze older time", isOn: $model.squeezesOlderTime)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("Keep the last \(window) at the right of each main graph, and squeeze older time into the rest, "
                + "more the older it is, so one graph covers the last \(whole). Older time is kept from when this is "
                + "turned on, while OpenTaskManager runs.")
    }
}

/// A squeezed main graph's time axis: how long ago each zone starts, under
/// the rules between them, the toggle in the window's part, and now at the
/// right. A label that would crowd another gives way, the window's edge and
/// the oldest end last. Laid out when the width changes, never per tick.
struct SqueezedTimeAxis: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0
    /// The room a graph keeps at its right for its newest value's marker.
    var headInset: CGFloat = 6

    private struct Mark: Identifiable {
        var text: String
        var x: CGFloat
        var id: String { text }
    }

    private static let font = NSFont.preferredFont(forTextStyle: .callout)
    private static let gap: CGFloat = 8

    private static func width(of text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    var body: some View {
        let warp = TimeWarp.standard
        let window = Double(AppModel.graphSpan) * model.samplingInterval
        let whole = Format.timeSpan(window * warp.span)
        let plot = max(width - headInset, 0)
        let marks = marks(window: window, plot: plot)
        let edge = plot * CGFloat(1 - warp.linearShare)
        let toggle = edge + Self.width(of: Format.timeSpan(window)) / 2 + 12
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                ForEach(marks) { mark in
                    Text(mark.text).fixedSize().offset(x: mark.x)
                }
                Text("now").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last \(whole), older time squeezed")
            GraphSqueezeToggle()
                .offset(x: toggle)
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
        .frame(maxWidth: .infinity, minHeight: GraphFitToggle.height, alignment: .leading)
        .help("The last \(Format.timeSpan(window)) at the right as usual; older time to the left, squeezed more at each rule, "
            + "back to \(whole) ago.")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The oldest end at the left, then each zone's start centred under its
    /// rule, as many as fit.
    private func marks(window: TimeInterval, plot: CGFloat) -> [Mark] {
        let warp = TimeWarp.standard
        guard plot > 0 else { return [] }
        let oldest = Format.timeSpan(window * warp.span)
        // Newest first: the window's edge matters most.
        let edges = warp.zoneEdges.map { age in
            let text = Format.timeSpan(window * age)
            return Mark(text: text, x: plot * CGFloat(1 - warp.offset(age: age)) - Self.width(of: text) / 2)
        }
        var shown = [Mark(text: oldest, x: 0)]
        for mark in edges {
            let start = mark.x
            let end = mark.x + Self.width(of: mark.text)
            let clear = shown.allSatisfy { other in
                end + Self.gap <= other.x || other.x + Self.width(of: other.text) + Self.gap <= start
            }
            if clear, start >= 0 { shown.append(mark) }
        }
        return shown.sorted { $0.x < $1.x }
    }
}
