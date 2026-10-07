import OTMKit
import SwiftUI

/// Temperatures, fans, clocks and power rails: the chip's hottest and
/// average die, the SSD and the battery over time, each fan's speed within
/// its range, and a table of every reading this Mac gives with its lowest
/// and highest since a reset point. macOS's thermal pressure has a row of its
/// own: it's a level, not a temperature.
struct SensorsDetail: View {
    /// Below this many rows the table is short enough to read without a search field.
    private static let searchThreshold = 12

    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// nil on a Mac (or VM) that reports no temperatures or fans.
    var sensors: SensorSample?
    var snapshot: SystemSnapshot

    var body: some View {
        let thermalState = snapshot.power.thermalState
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Thermals", subtitle: "Thermal pressure \(thermalState.rawValue)")
            stats(thermalState)
            if let sensors, !sensors.temperatures.isEmpty {
                temperatures(sensors)
            }
            if let sensors, !sensors.fans.isEmpty {
                FillGrid(minimum: 280) {
                    ForEach(sensors.fans) { fan in fanCard(fan, count: sensors.fans.count) }
                }
            }
            sensorTable(thermalState)
        }
    }

    private func stats(_ thermalState: ThermalState) -> some View {
        MetricStrip(tint: Theme.thermal) {
            if let chip = sensors?.hottest(.chip) {
                Stat(label: "Hottest die", number: chip, color: Theme.thermal, format: Format.celsius)
            }
            if let average = sensors?.average(.chip) {
                Stat(label: "Chip average", number: average, format: Format.celsius)
            }
            if let storage = sensors?.hottest(.storage) {
                Stat(label: "SSD", number: storage, color: Theme.sensor(.storage), format: Format.celsius)
            }
            if let battery = sensors?.hottest(.battery) {
                Stat(label: "Battery", number: battery, color: Theme.sensor(.battery), format: Format.celsius)
            }
            Stat(label: "Thermal pressure", value: thermalState.title, color: thermalState.color)
                .help(ThermalState.explanation)
            if sensors?.temperatures.isEmpty ?? true {
                CapabilityNote(label: "Temperatures", text: "Not reported",
                               detail: "macOS shares no temperature sensors on this Mac.")
            }
        }
    }

    private func temperatures(_ sensors: SensorSample) -> some View {
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

    private func fanCard(_ fan: SensorSample.Fan, count: Int) -> some View {
        let range = [fan.minimumRPM, fan.maximumRPM].compactMap { $0 }.map(Format.rpm).joined(separator: " – ")
        return ChartCard(title: count > 1 ? "Fan \(fan.id + 1)" : "Fan",
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

    /// Every reading grouped by part, with its lowest and highest since the
    /// reset point. The rows are AppKit (`SensorReadingTable`), so a tick only sets
    /// the figures that changed.
    private func sensorTable(_ thermalState: ThermalState) -> some View {
        let all = model.sensorRows
        let rows = SensorTable.filter(all, matching: query)
        let pressure = SensorTable.pressureMatches(query)
        return Card(tint: Theme.thermal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Sensors and clocks").font(.headline).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if all.count >= Self.searchThreshold || !query.isEmpty {
                    SensorSearchField(text: $query)
                        .frame(minWidth: 110, idealWidth: 180, maxWidth: 180)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Lowest and highest since \(Self.time(model.sensorExtremes.since))")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .help("Every reading counts toward the range, one each \(Format.timeSpan(model.updateSpeed.rawValue)). "
                        + "A sensor that gives no reading leaves its range alone.")
                Button {
                    model.resetSensorExtremes()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help("Start every lowest and highest again from now")
                Spacer(minLength: 0)
            }
            SensorReadingTable(rows: rows, extremes: model.sensorExtremes, thermalState: pressure ? thermalState : nil)
            if all.isEmpty {
                noSensors()
            } else if rows.isEmpty, !pressure {
                Text("No sensor matches \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, SensorColumns.inset)
            }
        }
    }

    /// What a Mac with no sensors (a virtual machine) shows under the
    /// thermal pressure row, so the empty table reads as deliberate.
    private func noSensors() -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "thermometer.medium.slash")
                .font(.title2)
                .foregroundStyle(.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("No sensors on this Mac").font(.headline)
                Text("macOS reports no temperatures, fan speeds, clocks or power rails here, as is usual in a virtual "
                    + "machine. Thermal pressure comes from macOS itself, so it's always shown.")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
            }
        }
        .padding(.horizontal, SensorColumns.inset)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// "14:02:31", with the day too when it isn't today.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A small search field for the sensor table: a magnifying glass, the
/// text, and a clear button once there's something to clear. Esc clears it.
private struct SensorSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText)
            TextField("Filter", text: $text, prompt: Text("Filter"))
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter sensors")
    }
}
