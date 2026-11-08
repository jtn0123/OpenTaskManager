import Foundation
import OTMKit

/// Samples the sensors, and the power figures read alongside them, every
/// `interval` seconds until `seconds` have passed (at least once), keeping
/// each reading's range as the app's Thermals table does.
func sensorReport(over seconds: Double, interval: Double) async throws -> SensorExtremesReport {
    var sampling = SystemMonitor.Options()
    sampling.includeProcesses = false
    await monitor.setOptions(sampling)
    let sensorMonitor = SensorMonitor()
    let interval = max(interval, 0.25)
    if seconds >= 5 {
        FileHandle.standardError.write(Data("Sampling every \(Format.timeSpan(interval)) for \(Format.timeSpan(seconds))…\n".utf8))
    }
    // The baseline: clocks and component power are rates over an interval.
    _ = await monitor.sample()
    var extremes = SensorExtremes(since: Date())
    var readings: [SensorReading] = []
    var thermalState: ThermalState?
    var sensors: SensorSample?
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: .seconds(seconds))
    repeat {
        try await Task.sleep(for: .seconds(interval))
        async let reading = sensorMonitor.sample()
        let snapshot = await monitor.sample()
        sensors = await reading
        readings = SensorTable.readings(sensors: sensors, power: snapshot.power, gpus: snapshot.gpus)
        thermalState = snapshot.power.thermalState
        extremes.record(readings, thermalState: thermalState)
    } while clock.now < end
    return SensorExtremesReport(extremes: extremes, rows: readings, thermalState: thermalState, until: Date(),
                                interval: interval, sensors: sensors)
}

/// The report as a table by group: each reading now, with its lowest and
/// highest when `extremes`, or where it came from otherwise.
func sensorTable(_ report: SensorExtremesReport, extremes: Bool) -> String {
    func value(_ number: Double?, _ reading: SensorReading) -> String {
        number.map(reading.unit.format) ?? reading.note ?? "—"
    }
    var lines: [String] = []
    let pressure = report.thermalPressure
    var line = "\(pad("Thermal pressure", 26))\(pressure.now?.rawValue ?? "unknown")"
    if extremes, let mildest = pressure.mildest, let worst = pressure.worst {
        line += "  (mildest \(mildest.rawValue), worst \(worst.rawValue))"
    }
    lines.append(line)
    var group: SensorGroup?
    for row in report.rows {
        let reading = row.reading
        if reading.group != group {
            group = reading.group
            let columns = extremes
                ? pad("NOW", 12, right: true) + pad("LOWEST", 12, right: true) + pad("HIGHEST", 12, right: true)
                : pad("NOW", 12, right: true) + "  SOURCE"
            lines += ["", pad(reading.group.title.uppercased(), 26) + columns]
        }
        var text = "  " + pad(reading.label, 24) + pad(value(reading.value, reading), 12, right: true)
        if extremes {
            text += pad(value(row.lowest, reading), 12, right: true) + pad(value(row.highest, reading), 12, right: true)
        } else {
            text += "  " + reading.source.shortTitle + (reading.origin.map { " \($0)" } ?? "")
        }
        lines.append(text)
    }
    if report.rows.isEmpty {
        lines += ["", "No temperatures, fan speeds, clocks or power rails found."]
    }
    if extremes {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        lines += ["", "\(report.samples) samples every \(Format.timeSpan(report.interval)), "
            + "\(report.since.formatted(time)) to \(report.until.formatted(time))."]
    }
    return lines.joined(separator: "\n")
}

@MainActor
func sensorsCommand(_ options: Options) async throws {
    if options.json, options.extremes == nil {
        printJSON(await SensorMonitor().sample())
        return
    }
    let report = try await sensorReport(over: options.extremes ?? 0, interval: options.interval)
    if options.json {
        printJSON(report)
    } else {
        print(sensorTable(report, extremes: options.extremes != nil))
    }
}
