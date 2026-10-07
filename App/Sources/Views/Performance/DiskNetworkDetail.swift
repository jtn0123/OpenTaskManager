import OTMKit
import SwiftUI

struct DiskDetail: View {
    @Environment(AppModel.self) private var model
    var disk: DiskSample
    var snapshot: SystemSnapshot

    var body: some View {
        let reads = model.diskReadHistory[disk.id]?.values ?? []
        let writes = model.diskWriteHistory[disk.id]?.values ?? []
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Disk \(disk.bsdName.replacingOccurrences(of: "disk", with: ""))", subtitle: disk.model ?? disk.bsdName)
            MetricStrip(tint: Theme.disk) {
                Stat(label: "Read", number: disk.readBytesPerSecond, color: Theme.disk, format: Format.bytesPerSecond)
                Stat(label: "Write", number: disk.writeBytesPerSecond, color: Theme.diskSecondary, format: Format.bytesPerSecond)
                Stat(label: "Active time", number: disk.activeFraction) { Format.percent($0) }
                Stat(label: "IOPS", number: disk.readOperationsPerSecond + disk.writeOperationsPerSecond) { Format.fixed($0, 0) }
                Stat(label: "Read since boot", value: Format.bytes(disk.totalRead))
                Stat(label: "Written since boot", value: Format.bytes(disk.totalWritten))
            }
            GraphPanel(title: "Transfer rate (read solid, write dashed)", trailing: "",
                       series: [
                           GraphSeries(values: reads, color: Theme.disk),
                           GraphSeries(values: writes, color: Theme.diskSecondary, fill: false, dashed: true),
                       ],
                       height: DetailGraph.primary, minimumCeiling: 1_048_576, axis: Format.bytesPerSecond, axisUnits: .binaryBytes)
            TopAppsCard(title: "Disk I/O", symbol: "internaldrive", color: Theme.disk, groups: model.appGroups,
                        metric: \.diskRate, format: { Format.bytesPerSecond($0.diskRate) })

            let volumes = snapshot.volumes.filter { $0.physicalDisk == disk.bsdName }
            if !volumes.isEmpty {
                volumeList(volumes)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let size = disk.size { FactRow(label: "Capacity", value: Format.bytes(size)) }
                FactRow(label: "Type", value: disk.isSolidState == true ? "SSD" : disk.isSolidState == false ? "Rotational" : "Unknown")
                if let isInternal = disk.isInternal { FactRow(label: "Location", value: isInternal ? "Internal" : "External") }
            }
        }
    }

    /// The volumes stored on this disk.
    private func volumeList(_ volumes: [VolumeInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volumes").font(.headline)
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(volume.name)
                        Spacer()
                        Text("\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                    let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                    ProgressView(value: used).tint(Theme.pressure(used))
                }
            }
        }
    }
}

// MARK: - Network

struct NetworkDetail: View {
    @Environment(AppModel.self) private var model
    var link: NetworkInterfaceSample
    var snapshot: SystemSnapshot

    var body: some View {
        let received = model.networkInHistory[link.id]?.values ?? []
        let sent = model.networkOutHistory[link.id]?.values ?? []
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: link.displayName, subtitle: link.name)
            MetricStrip(tint: Theme.network) {
                Stat(label: "Receive", number: link.receivedBytesPerSecond, color: Theme.network, format: Format.bitsPerSecond)
                Stat(label: "Send", number: link.sentBytesPerSecond, color: Theme.networkSecondary, format: Format.bitsPerSecond)
                Stat(label: "Received", value: Format.bytes(link.totalReceived))
                Stat(label: "Sent", value: Format.bytes(link.totalSent))
            }
            GraphPanel(title: "Throughput (receive solid, send dashed)", trailing: "",
                       series: [
                           GraphSeries(values: received, color: Theme.network),
                           GraphSeries(values: sent, color: Theme.networkSecondary, fill: false, dashed: true),
                       ],
                       height: DetailGraph.primary, minimumCeiling: 125_000, axis: Format.bitsPerSecond, axisUnits: .bits)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                FactRow(label: "Connection", value: link.kind.rawValue.capitalized)
                if let speed = link.linkSpeed { FactRow(label: "Link speed", value: Format.bitsPerSecond(Double(speed) / 8)) }
                ForEach(link.addresses, id: \.self) { address in
                    FactRow(label: address.contains(":") ? "IPv6" : "IPv4", value: address)
                }
            }
        }
    }
}
