import AppKit
import OTMKit
import SwiftUI

/// Whether Performance's graphs, while their window is still filling, fit
/// what's been collected across their width or keep the full window with
/// the samples at its right. One setting, `GraphFit.key`, for every graph
/// on the page, so they still share one window. On by default, so what's
/// been collected fills the graphs rather than a sliver at the right of an
/// empty, hatched window; off keeps the labelled 5-minute window from the
/// start. It has no effect once every sample would fit only the full
/// window, and then its toggle goes.
///
/// A fitted window steps (`GraphCoverage.fittedCapacity`) rather than
/// growing with every sample: the graphs keep scrolling between samples,
/// and their axis and caption ("35 s collected · 40 s window") change every
/// 30 s at most.
enum GraphFit {
    static let key = "fitsCollectedGraphData"
    /// Fitted, until the user picks the full window.
    static let standard = true

    /// The page's window for `samples` collected out of `span`.
    static func window(samples: Int, span: Int = AppModel.graphSpan, fits: Bool) -> Int {
        fits ? GraphCoverage.fittedCapacity(samples: samples, span: span) : span
    }
}

extension EnvironmentValues {
    /// Whether the page's graphs can be fitted to what's been collected:
    /// the main graph's time axis then shows the toggle (`TimeAxis.offersFit`).
    @Entry var offersGraphFit = false
}

/// The Fit collected data toggle, in the time axis of a Performance
/// detail's main graph, beside the window it changes.
struct GraphFitToggle: View {
    /// Its height, which the time axis keeps once it's gone.
    static let height: CGFloat = {
        let box = NSButton(checkboxWithTitle: "Fit collected data", target: nil, action: nil)
        box.controlSize = .small
        return ceil(box.fittingSize.height)
    }()

    @Environment(AppModel.self) private var model
    @AppStorage(GraphFit.key) private var fits = GraphFit.standard

    var body: some View {
        let window = Format.timeSpan(Double(AppModel.graphSpan) * model.updateSpeed.rawValue)
        Toggle("Fit collected data", isOn: $fits)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("Stretch what's been collected so far across every graph on this page, rather than show it at the right "
                + "of the \(window) window. The window grows in steps until it's full.")
    }
}
