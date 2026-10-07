import OTMKit
import SwiftUI

/// "Apps using the network" on the Performance page's network detail: the
/// busiest apps stacked over the last few minutes, and what each is
/// receiving and sending now. It reads only `NetworkActivityStore`, so it
/// redraws when nettop is read every 3 s, not on every tick.
struct NetworkAppsSection: View {
    @Environment(AppModel.self) private var model
    /// The page's window, in the main sampler's samples (`GraphFit`).
    @Environment(\.graphWindow) private var window
    @AppStorage("networkByProcess") private var byProcess = false

    private static let bands = 5
    private static let rows = 8

    var body: some View {
        let store = model.networkActivity
        let history = byProcess ? store.processes : store.apps
        Card(tint: Theme.network) {
            header
            if !store.hasMeasured {
                if store.isUnavailable {
                    UnavailableNote(text: Unavailable.processNetwork)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring which apps are using the network…").foregroundStyle(.secondaryText)
                    }
                    .font(.callout)
                }
            } else if history.isQuiet {
                quiet(seconds: Double(history.length) * NetworkActivityStore.refreshSeconds)
            } else {
                breakdown(history, store: store)
            }
        }
        .task { await store.track(model: model) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(byProcess ? "Processes using the network" : "Apps using the network").font(.headline)
                Text("Received and sent on every interface · updates every \(Format.timeSpan(NetworkActivityStore.refreshSeconds))")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Picker("Show", selection: $byProcess) {
                Text("Apps").tag(false)
                Text("Processes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Fold helper processes into their app, or list every process on its own")
        }
    }

    /// Said instead of drawing an empty chart.
    private func quiet(seconds: TimeInterval) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(Theme.network.opacity(0.55))
            Text(byProcess ? "No process is using the network" : "No app is using the network")
                .font(.callout.weight(.medium))
            Text("Nothing sent or received in the last \(Format.roughDuration(seconds)).")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func breakdown(_ history: NetworkActivityHistory<Int32>, store: NetworkActivityStore) -> some View {
        let ranking = history.ranking(bands: Self.bands, rows: Self.rows)
        let other = history.remainder(excluding: ranking.bands)
        let colors = Theme.appColors(for: ranking.bands.map(Int64.init), in: byProcess ? "network processes" : "network")
        let series = ranking.bands.enumerated().map { GraphSeries(values: history.totals[$1] ?? [], color: colors[$0]) }
            + [GraphSeries(values: other, color: Theme.other)]
        let peak = ranking.rows.compactMap { history.latest[$0]?.total }.max() ?? 0
        // The throughput graph's window, in the store's readings.
        let span = NetworkActivityStore.graphSpan(interval: model.updateSpeed.rawValue, samples: window)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 3) {
                GraphView(series: series, capacity: span, glows: true, stacked: true,
                          minimumCeiling: 125_000, axis: Format.bitsPerSecond, axisUnits: .bits, cornerRadius: 8)
                    .chartFrame(height: DetailGraph.secondary, tint: Theme.network)
                    // Scroll across the store's interval, not the main sampler's.
                    .environment(\.sampleInterval, NetworkActivityStore.refreshSeconds)
                // Named as the page's window: the store's readings round a fitted one to 3 s.
                TimeAxis()
            }
            VStack(spacing: 4) {
                columnTitles
                ForEach(ranking.rows, id: \.self) { pid in
                    let usage = history.latest[pid] ?? NetworkUsage(received: 0, sent: 0, processes: 0)
                    let identity = store.identity(pid)
                    let band = ranking.bands.firstIndex(of: pid)
                    NetworkUsageRow(
                        swatch: band.map { colors[$0] } ?? Theme.other, icon: identity.icon, name: identity.name,
                        badge: !byProcess && usage.processes > 1 ? "(\(usage.processes))" : nil,
                        usage: usage, fraction: peak > 0 ? usage.total / peak : 0
                    )
                    .help(help(identity.name, usage))
                }
                if ranking.rows.allSatisfy({ history.latest[$0] == nil }) {
                    Text("Quiet right now.").font(.callout).foregroundStyle(.secondaryText).padding(.horizontal, 6)
                }
            }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 8) {
            Text(byProcess ? "Process" : "App")
            Spacer(minLength: 8)
            Text("Receive").frame(width: NetworkUsageRow.rateColumnWidth, alignment: .trailing)
            Text("Send").frame(width: NetworkUsageRow.rateColumnWidth, alignment: .trailing)
        }
        .font(.tableText)
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 6)
    }

    private func help(_ name: String, _ usage: NetworkUsage) -> String {
        let processes = !byProcess && usage.processes > 1 ? " (\(usage.processes) processes)" : ""
        return "\(name)\(processes): receiving \(Format.bitsPerSecond(usage.received)), sending \(Format.bitsPerSecond(usage.sent))"
    }
}

/// The apps receiving and sending the most right now, beside Top CPU, Memory
/// and Energy on the Overview. Like the Performance section, it reads only
/// the store, and nettop runs only while the card is on screen.
struct TopNetworkCard: View {
    @Environment(AppModel.self) private var model

    /// Quiet readings an app keeps its row for, so a pause in the traffic
    /// doesn't empty the card or swap it for the Overview's one-line strip.
    static let holdReadings = 10

    /// Whether the card has rows: something moved within the hold. Without
    /// any, the Overview shows a one-line strip in its place.
    static func hasRanking(_ store: NetworkActivityStore) -> Bool {
        store.hasMeasured && store.apps.hasMoved(inLast: holdReadings)
    }

    var body: some View {
        let store = model.networkActivity
        let history = store.apps
        let top = history.ranking(bands: 0, rows: 6, holding: Self.holdReadings).rows
        let peak = top.compactMap { history.latest[$0]?.total }.max() ?? 0
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Top Network", systemImage: "network")
                    .font(.headline)
                    .foregroundStyle(Theme.network)
                Spacer(minLength: 8)
                Text("every \(Format.timeSpan(NetworkActivityStore.refreshSeconds))")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .help("Read with nettop every \(Format.timeSpan(NetworkActivityStore.refreshSeconds)) while this page is open")
            }
            if !store.hasMeasured {
                if store.isUnavailable {
                    UnavailableNote(text: Unavailable.processNetwork)
                } else {
                    Text("Measuring…").font(.callout).foregroundStyle(.secondaryText)
                }
            } else if top.isEmpty {
                Text("Quiet right now.").font(.callout).foregroundStyle(.secondaryText)
            }
            VStack(spacing: 4) {
                ForEach(top, id: \.self) { pid in
                    let usage = history.latest[pid] ?? NetworkUsage(received: 0, sent: 0, processes: 0)
                    let identity = store.identity(pid)
                    NetworkUsageRow(icon: identity.icon, name: identity.name, usage: usage,
                                    fraction: peak > 0 ? usage.total / peak : 0)
                        .help("\(identity.name): receiving \(Format.bitsPerSecond(usage.received)), sending \(Format.bitsPerSecond(usage.sent))")
                }
            }
        }
        .task { await store.track(model: model) }
    }
}

/// One app or process in the network lists: its receive and send rates in
/// the Network page's colours, over a bar for its share of the busiest row.
struct NetworkUsageRow: View {
    /// Wide enough for the widest rate ("99.9 Mbps") and its arrow, so the
    /// columns line up from row to row.
    static let rateColumnWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        return ceil(("99.9 Mbps" as NSString).size(withAttributes: [.font: font]).width) + 14
    }()

    var swatch: Color?
    var icon: NSImage
    var name: String
    var badge: String?
    var usage: NetworkUsage
    var fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2.5).fill(swatch.gradient).frame(width: 10, height: 10)
            }
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            Text(name).lineLimit(1)
            if let badge {
                Text(badge).foregroundStyle(.secondaryText).fixedSize()
            }
            Spacer(minLength: 8)
            rate(usage.received, symbol: "arrow.down", color: Theme.network)
            rate(usage.sent, symbol: "arrow.up", color: Theme.networkSecondary)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            // Behind text, so the bar keeps the pastel fill shade.
            let bar = Theme.network.fillShade
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [bar.opacity(0.30), bar.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }

    private func rate(_ value: Double, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(color)
            Text(Format.bitsPerSecond(value)).monospacedDigit().foregroundStyle(.secondaryText).lineLimit(1)
        }
        .frame(width: Self.rateColumnWidth, alignment: .trailing)
    }
}
