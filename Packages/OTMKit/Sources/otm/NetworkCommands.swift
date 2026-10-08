import Foundation
import OTMKit

/// `otm netconfig [--all] [--json]`: the network cards (ports, the
/// configuration, mounted shares) and the firewall's card.
func netconfigCommand(_ options: Options) async {
    async let reading = FirewallReader.read()
    let ports = SystemInfoReader.readNetwork()
    let configuration = NetworkConfigurationReader.read()
    let firewall = await reading
    if options.json {
        guard let data = try? SystemReportDocument.networkJSON(ports, configuration: configuration, firewall: firewall,
                                                               includeIdentifiers: options.all) else {
            fail("could not encode JSON")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(SystemReport.networkText(ports, configuration: configuration, firewall: firewall, includeIdentifiers: options.all),
              terminator: "")
    }
}

struct ListeningPort: Encodable {
    let pid: Int32
    let process: String
    let proto: String
    let address: String
    let port: Int
}

/// TCP listeners and bound UDP sockets, from the system-wide connection walk.
func listeningPorts(_ connections: [Connection]) -> [ListeningPort] {
    connections.compactMap { connection -> ListeningPort? in
        guard connection.kind.acceptsInbound, let port = connection.local.port else { return nil }
        return ListeningPort(pid: connection.pid, process: connection.processName, proto: connection.transport.rawValue,
                             address: connection.local.address, port: port)
    }
    .sorted { ($0.port, $0.pid, $0.proto) < ($1.port, $1.pid, $1.proto) }
}

func portsCommand(_ options: Options) {
    let sample = ConnectionSampler.sample()
    if ProcessInfo.processInfo.environment["OTM_CONNECTION_WALK_TIMING"] == "1" {
        let timing = "Socket walk: wall \(sample.duration) s, thread CPU \(sample.cpuDuration) s, "
            + "\(sample.scannedProcesses) processes scanned, \(sample.hiddenProcesses) unreadable\n"
        FileHandle.standardError.write(Data(timing.utf8))
    }
    let ports = listeningPorts(sample.connections)
    if options.json {
        printJSON(ports)
    } else {
        print(pad("PROTO", 6) + pad("ADDRESS", 26) + pad("PORT", 7, right: true) + pad("PID", 8, right: true) + "  PROCESS")
        for port in ports {
            print(pad(port.proto, 6) + pad(port.address, 26) + pad(String(port.port), 7, right: true)
                + pad(String(port.pid), 8, right: true) + "  " + port.process)
        }
        if sample.hiddenProcesses > 0 {
            print("\n\(sample.hiddenProcesses) processes of root and other users hidden (macOS restricts them; try sudo)")
        }
    }
}

@MainActor
func netCommand(_ options: Options) async throws {
    guard let before = ProcessNetwork.read() else { fail("nettop couldn't run") }
    let started = Date()
    try await Task.sleep(for: .seconds(options.interval))
    guard let after = ProcessNetwork.read() else { fail("nettop couldn't run") }
    let rates = Array(ProcessNetwork.rates(from: before, to: after, interval: Date().timeIntervalSince(started)).prefix(options.count))
    if options.json {
        printJSON(rates)
    } else if rates.isEmpty {
        print("No process sent or received anything in \(Format.timeSpan(options.interval)).")
    } else {
        print(pad("PID", 7, right: true) + pad("RECEIVED", 13, right: true) + pad("SENT", 13, right: true) + "  PROCESS")
        for rate in rates {
            print(pad(String(rate.pid), 7, right: true) + pad(Format.bitsPerSecond(rate.bytesInPerSecond), 13, right: true)
                + pad(Format.bitsPerSecond(rate.bytesOutPerSecond), 13, right: true) + "  " + rate.name)
        }
    }
}
