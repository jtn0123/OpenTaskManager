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
    @Environment(\.detailPaneHeight) private var pane
    @State private var query = ""
    /// nil on a Mac (or VM) that reports no temperatures or fans.
    var sensors: SensorSample?
    var snapshot: SystemSnapshot

    /// The hottest die's reading lights the level bar on this scale.
    private static let levelScale = 100.0

    var body: some View {
        let thermalState = snapshot.power.thermalState
        VStack(alignment: .leading, spacing: 16) {
            DeviceHeader(title: "Thermals", subtitle: subtitle(thermalState), level: level(thermalState))
            if let sensors, !sensors.temperatures.isEmpty {
                temperatures(sensors, thermalState: thermalState)
            } else {
                pressure(thermalState)
            }
            if let sensors, !sensors.fans.isEmpty {
                FillGrid(minimum: 280) {
                    ForEach(sensors.fans) { fan in fanCard(fan, count: sensors.fans.count) }
                }
            }
            sensorTable(thermalState)
                .samplingDemand(.sensorTable)
        }
        .samplingDemand(.sensors)
    }

    /// The thermal pressure, where the level bar gives the hottest die; with
    /// no temperatures the bar gives the pressure, so this says why.
    private func subtitle(_ thermalState: ThermalState) -> String {
        sensors?.hottest(.chip) == nil ? "No temperature sensors reported" : "Thermal pressure \(thermalState.rawValue)"
    }

    /// The hottest die on a 0 to 100 °C scale, or, with no temperatures,
    /// how far macOS's thermal pressure has risen.
    private func level(_ thermalState: ThermalState) -> LevelRow {
        if let chip = sensors?.hottest(.chip) {
            return LevelRow(fraction: min(max(chip / Self.levelScale, 0), 1), color: Theme.thermal, value: chip, format: Format.celsius,
                            caption: "hottest die", label: "Hottest die temperature", figureWidth: 72)
        }
        return LevelRow(fraction: thermalState.level, color: Theme.thermal, text: thermalState.title, caption: "thermal pressure",
                        label: "Thermal pressure", figureWidth: 0)
    }

    @ViewBuilder
    private func figures(_ thermalState: ThermalState) -> some View {
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

    /// With no temperatures to graph (a virtual machine), macOS's thermal
    /// pressure over the same minutes, its four levels marked by the grid.
    private func pressure(_ thermalState: ThermalState) -> some View {
        DeviceCard(tint: Theme.thermal, footnote: "Nominal at the foot, fair and serious at the grid's lines, critical at the top: how hard "
                   + "macOS is holding back to stay cool. A level, not a temperature.") {
            DeviceCaption(title: "Thermal pressure", trailing: thermalState.title)
        } plot: {
            GraphView(series: [GraphSeries(values: model.thermalPressureHistory.values, color: Theme.thermal)], maxValue: 1,
                      glows: true, cornerRadius: 8)
                .heroPlot(height: Hero.height(pane: pane, extra: 2 * Hero.legendLine), tint: Theme.thermal, rows: 3)
        } figures: {
            figures(thermalState)
        }
    }

    private func temperatures(_ sensors: SensorSample, thermalState: ThermalState) -> some View {
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
        return DeviceCard(tint: Theme.thermal, legend: legend) {
            DeviceCaption(title: "Temperatures", trailing: sensors.hottest(.chip).map { "chip \(Format.celsius($0))" } ?? "")
        } plot: {
            GraphView(series: series, glows: true, minimumCeiling: 60, axis: Format.celsius, cornerRadius: 8)
                .heroPlot(height: Hero.height(pane: pane, extra: 2 * Hero.legendLine), tint: Theme.thermal)
        } figures: {
            figures(thermalState)
        }
    }

    /// The speed in rpm first, then its share of the fan's maximum, the
    /// scale the graph and the Thermals table draw it on, so a fan at its
    /// minimum never reads as stopped.
    private func fanCard(_ fan: SensorSample.Fan, count: Int) -> some View {
        let range = [fan.minimumRPM, fan.maximumRPM].compactMap { $0 }.map(Format.rpm).joined(separator: " – ")
        let share = fan.shareOfMaximum.map { " · \(Format.percent($0)) of maximum" } ?? ""
        return ChartCard(title: count > 1 ? "Fan \(fan.id + 1)" : "Fan",
                         trailing: fan.isStopped ? "stopped" : Format.rpm(fan.rpm), tint: Theme.fan,
                         legend: [
                             LegendItem(name: "Speed", color: Theme.fan, value: fan.isStopped ? "Stopped" : Format.rpm(fan.rpm) + share),
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
            // The since line and Reset are the table's, so they stick to the
            // top of the page with the column titles.
            SensorReadingTable(rows: rows, extremes: model.sensorExtremes, thermalState: pressure ? thermalState : nil,
                               since: "Lowest and highest since \(Self.time(model.sensorExtremes.since))",
                               sinceHelp: "Every reading counts toward the range, one each \(Format.timeSpan(model.updateSpeed.rawValue)). "
                                   + "A sensor that gives no reading leaves its range alone.") {
                model.resetSensorExtremes()
            }
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
