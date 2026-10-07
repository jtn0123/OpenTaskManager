import Darwin
import Foundation
import OTMKit

// `otm netquality` and `otm diskspeed`. Both save their results with the
// app's, so the Performance page's history shows them too.

/// `otm netquality [INTERFACE] [--json]`: one networkQuality run, bound to
/// INTERFACE where the tool allows it.
func netQualityCommand(_ options: Options) async {
    let interface = options.positional.first
    if !options.json {
        let link = interface.map { " on \($0)" } ?? ""
        let notice = "Testing\(link) for about \(Int(NetworkQuality.typicalSeconds)) s. This deliberately fills the connection…\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    do throws(NetworkQualityError) {
        let result = try await NetworkQuality.run(interface: interface)
        _ = try? SpeedTestHistory.networkQuality.append(result)
        if options.json {
            printJSON(result)
        } else {
            print(networkQualitySummary(result))
        }
    } catch {
        fail(error.message)
    }
}

func networkQualitySummary(_ result: NetworkQualityResult) -> String {
    func rate(_ bits: Double?) -> String { bits.map { Format.bitsPerSecond($0 / 8) } ?? "not tested" }
    var lines = [
        "Download        \(rate(result.downloadBitsPerSecond))",
        "Upload          \(rate(result.uploadBitsPerSecond))",
    ]
    if let rpm = result.responsiveness, let rating = result.rating {
        let delay = NetworkResponsiveness.loadedLatency(rpm: rpm).map { ", about \(Format.fixed($0, 0)) ms round trip under load" } ?? ""
        lines.append("Responsiveness  \(Int(rpm.rounded()).formatted()) RPM: \(rating.title)\(delay)")
    }
    if let idle = result.idleLatency { lines.append("Idle latency    \(Format.fixed(idle, 0)) ms") }
    lines.append("Interface       \(result.interface ?? result.requestedInterface ?? "system default") (\(result.configurationSummary))")
    if let endpoint = result.endpoint { lines.append("Server          \(endpoint)") }
    if let bytes = result.bytesTransferred { lines.append("Data used       \(Format.bytes(bytes))") }
    if let rating = result.rating { lines += ["", rating.summary] }
    return lines.joined(separator: "\n")
}

/// `otm diskspeed [PATH] [--size MB] [--json]`: sequential and 4K random
/// speed of the volume holding PATH, on a temporary file it always deletes.
/// Ctrl-C stops the test cleanly.
func diskSpeedCommand(_ options: Options) {
    var folder = DiskSpeedTest.defaultFolder
    var configuration = DiskSpeedConfiguration()
    var arguments = options.positional.makeIterator()
    while let argument = arguments.next() {
        if argument == "--size" {
            guard let megabytes = arguments.next().flatMap(UInt64.init), megabytes > 0 else { fail("--size needs a size in MB") }
            configuration.fileSize = megabytes << 20
        } else {
            folder = (argument as NSString).expandingTildeInPath
        }
    }

    let cancellation = DiskSpeedCancellation()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { cancellation.cancel() }
    interrupt.resume()
    defer { interrupt.cancel() }

    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    let result: DiskSpeedResult
    do throws(DiskSpeedError) {
        result = try DiskSpeedTest.run(in: folder, configuration: configuration, cancellation: cancellation) { progress in
            guard showsProgress else { return }
            let line = "\(progress.phase.title): \(Format.percent(progress.phaseFraction)) · \(Format.megabytesPerSecond(progress.bytesPerSecond))"
            FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
        }
    } catch {
        if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
        fail(error.message)
    }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    _ = try? SpeedTestHistory.diskSpeed.append(result)
    if options.json {
        printJSON(result)
    } else {
        print(diskSpeedSummary(result, requested: configuration.fileSize))
    }
}

func diskSpeedSummary(_ result: DiskSpeedResult, requested: UInt64) -> String {
    let volume = result.volume
    let device = [volume.device, volume.physicalDisk.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
    var lines = [
        "\(volume.name) (\(volume.fileSystem)\(device.isEmpty ? "" : ", \(device)")), \(Format.bytes(result.freeBytes)) free",
        "",
        pad("", 18) + pad("MB/s", 10, right: true) + pad("IOPS", 10, right: true),
    ]
    for phase in DiskSpeedPhase.allCases {
        let measurement = result.measurement(phase)
        let speed = Format.megabytesPerSecond(measurement.bytesPerSecond).replacingOccurrences(of: " MB/s", with: "")
        let operations = Format.operationsPerSecond(measurement.operationsPerSecond).replacingOccurrences(of: " IOPS", with: "")
        lines.append(pad(phase.title, 18) + pad(speed, 10, right: true) + pad(operations, 10, right: true))
    }
    lines.append("")
    if result.configuration.fileSize < requested {
        lines.append("Used \(Format.wholeBytes(result.configuration.fileSize)): the test file never takes more than a tenth of the free space.")
    }
    lines.append(DiskSpeedTest.methodNote(result))
    return lines.joined(separator: "\n")
}
