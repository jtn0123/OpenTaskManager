import OTMKit
import SwiftUI

/// Temperatures and fans: the chip's hottest and average die, the SSD and the
/// battery over time, each fan's speed within its range, and every sensor's
/// lowest and highest reading since launch.
struct SensorsDetail: View {
    /// The sensor table's narrowest width with range bars: a label, three
    /// temperatures and a bar of `RangeBar`'s minimum, with the spacing between.
    private static let barsWidth: CGFloat = 490

    @Environment(AppModel.self) private var model
    @State private var tableWidth: CGFloat = 0
    var sensors: SensorSample
    var snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Thermals", subtitle: "Thermal state \(snapshot.power.thermalState.rawValue)")
            stats()
            temperatures()
            if !sensors.fans.isEmpty {
                FillGrid(minimum: 280) {
                    ForEach(sensors.fans) { fan in fanCard(fan) }
                }
            }
            sensorTable()
        }
    }

    private func temperatures() -> some View {
        let history = model.sensorHistory
        var series: [GraphSeries] = []
        var legend: [LegendItem] = []
        if let chip = sensors.hottest(.chip) {
            series.append(GraphSeries(values: history.hottest[.chip]?.values ?? [], color: Theme.thermal))
            series.append(GraphSeries(values: history.chipAverage.values, color: Theme.thermal.opacity(0.7), fill: false, dashed: true))
            legend.append(LegendItem(name: "Chip, hottest die", color: Theme.thermal, value: Format.celsius(chip)))
            let average = sensors.average(.chip).map(Format.celsius) ?? "—"
            legend.append(LegendItem(name: "Chip, average", color: Theme.thermal.opacity(0.7), value: average))
        }
        for kind in [SensorKind.storage, .battery] {
            guard let celsius = sensors.hottest(kind) else { continue }
            series.append(GraphSeries(values: history.hottest[kind]?.values ?? [], color: Theme.sensor(kind), fill: false))
            legend.append(LegendItem(name: kind.title, color: Theme.sensor(kind), value: Format.celsius(celsius)))
        }
        return ChartCard(title: "Temperatures", trailing: sensors.hottest(.chip).map { "chip \(Format.celsius($0))" } ?? "",
                         tint: Theme.thermal, legend: legend) {
            GraphView(series: series, glows: true, minimumCeiling: 60, axis: Format.celsius, cornerRadius: 8)
                .chartFrame(height: DetailGraph.primary, tint: Theme.thermal)
        }
    }

    private func fanCard(_ fan: SensorSample.Fan) -> some View {
        let range = [fan.minimumRPM, fan.maximumRPM].compactMap { $0 }.map(Format.rpm).joined(separator: " – ")
        return ChartCard(title: sensors.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan",
                         trailing: fan.isStopped ? "stopped" : Format.rpm(fan.rpm), tint: Theme.fan,
                         legend: [
                             LegendItem(name: "Speed", color: Theme.fan, value: fan.fraction.map { "\(Format.percent($0)) of range" } ?? "—"),
                             LegendItem(name: "Range", color: Theme.other, value: range.isEmpty ? "—" : range),
                         ]) {
            GraphView(series: [GraphSeries(values: model.sensorHistory.fans[fan.id]?.values ?? [], color: Theme.fan)],
                      maxValue: fan.maximumRPM, glows: true, minimumCeiling: 2000, axis: Format.rpm, cornerRadius: 8)
                .chartFrame(height: DetailGraph.compact, tint: Theme.fan)
        }
    }

    private func stats() -> some View {
        MetricStrip(tint: Theme.thermal) {
            if let chip = sensors.hottest(.chip) {
                Stat(label: "Hottest die", number: chip, color: Theme.thermal, format: Format.celsius)
            }
            if let average = sensors.average(.chip) {
                Stat(label: "Chip average", number: average, format: Format.celsius)
            }
            if let storage = sensors.hottest(.storage) {
                Stat(label: "SSD", number: storage, color: Theme.sensor(.storage), format: Format.celsius)
            }
            if let battery = sensors.hottest(.battery) {
                Stat(label: "Battery", number: battery, color: Theme.sensor(.battery), format: Format.celsius)
            }
            Stat(label: "Thermal state", value: snapshot.power.thermalState.rawValue.capitalized)
        }
    }

    /// Every sensor with its reading now and its range since launch, drawn as
    /// a bar from lowest to highest with a tick at the current reading. In a
    /// narrow pane the figures stay and the bars go, so no row runs past the card.
    private func sensorTable() -> some View {
        let ranges = model.sensorHistory.ranges
        let bars = tableWidth == 0 || tableWidth >= Self.barsWidth
        return Card(tint: Theme.thermal) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensors").font(.headline)
                Spacer()
                Text("lowest and highest since launch").font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Sensor")
                    Text("Now").gridColumnAlignment(.trailing)
                    Text("Lowest").gridColumnAlignment(.trailing)
                    Text("Highest").gridColumnAlignment(.trailing)
                    if bars {
                        Text("20 °C – 110 °C").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                ForEach(sensors.temperatures) { reading in
                    let range = ranges[reading.name] ?? reading.celsius...reading.celsius
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.sensor(reading.kind)).frame(width: 7, height: 7)
                            Text(reading.label)
                        }
                        Text(Format.celsius(reading.celsius)).fontWeight(.medium)
                        Text(Format.celsius(range.lowerBound)).foregroundStyle(.secondaryText)
                        Text(Format.celsius(range.upperBound)).foregroundStyle(.secondaryText)
                        if bars {
                            RangeBar(range: range, value: reading.celsius, color: Theme.sensor(reading.kind))
                                .frame(minWidth: 120, maxWidth: .infinity)
                                .frame(height: 8)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
    }
}

/// A sensor's range since launch on a fixed 20–110 °C scale, with a tick at
/// the current reading.
private struct RangeBar: View {
    private static let scale = 20.0...110.0
    var range: ClosedRange<Double>
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let start = position(range.lowerBound) * width
            let end = max(position(range.upperBound) * width, start + 3)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: end - start)
                    .offset(x: start)
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5)
                    .offset(x: min(max(position(value) * width - 1.25, 0), width - 2.5))
            }
        }
    }

    private func position(_ celsius: Double) -> Double {
        min(max((celsius - Self.scale.lowerBound) / (Self.scale.upperBound - Self.scale.lowerBound), 0), 1)
    }
}
