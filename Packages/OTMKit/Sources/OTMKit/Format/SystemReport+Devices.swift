import Foundation

/// The System page's attached-device cards: USB, Thunderbolt, Bluetooth,
/// and audio and video. Each device is a heading that reads as one compact
/// row (its name, how it's connected and one status), with the rest of its
/// facts as detail rows the card shows when the device is opened.
extension SystemReport {
    static func deviceSections(_ devices: PeripheralInventory?) -> [InfoSection] {
        guard let devices else {
            return [
                InfoSection(kind: .usb, title: "USB", rows: [InfoRow("Devices", "Checking…")]),
                InfoSection(kind: .bluetooth, title: "Bluetooth", rows: [InfoRow("Devices", "Checking…")]),
                InfoSection(kind: .audio, title: "Audio and Video", rows: [InfoRow("Devices", "Checking…")]),
            ]
        }
        var sections = [InfoSection(kind: .usb, title: "USB", rows: usb(devices.usb))]
        // A Mac without Thunderbolt gets no card, as one without a battery doesn't.
        if devices.thunderbolt.value?.hasHardware != false {
            sections.append(InfoSection(kind: .thunderbolt, title: "Thunderbolt and USB4", rows: thunderbolt(devices.thunderbolt)))
        }
        sections.append(InfoSection(kind: .bluetooth, title: "Bluetooth", rows: bluetooth(devices.bluetooth)))
        sections.append(InfoSection(kind: .audio, title: "Audio and Video", rows: audioAndVideo(devices.audio, devices.cameras)))
        return sections
    }

    private static let unreadable = InfoRow("Devices", "Couldn't read", status: .unknown)

    /// Bus tree order, each device as deep as the hubs it's behind.
    private static func usb(_ reading: DeviceReading<USBReport>) -> [InfoRow] {
        guard let report = reading.value else { return [unreadable] }
        guard !report.devices.isEmpty else {
            return [InfoRow("Devices", report.buses == 0 ? "No USB buses found" : "None connected")]
        }
        var rows: [InfoRow] = []
        for device in report.devices {
            rows.append(InfoRow(device.name, device.speed ?? "", isHeading: true, state: device.isBuiltIn ? "built-in" : nil,
                                depth: device.depth))
            if let vendor = device.vendor { rows.append(InfoRow("Maker", vendor, isDetail: true)) }
            // The hub it hangs off keeps the tree readable as plain text.
            rows.append(InfoRow("Connected to", device.hub ?? device.bus, isDetail: true))
            if let power = device.power { rows.append(InfoRow("Power", power, isDetail: true)) }
            if let ids = device.idPair { rows.append(InfoRow("Vendor:product", ids, isCode: true, isDetail: true)) }
            if let serial = device.serialNumber {
                rows.append(InfoRow("Serial number", serial, isSensitive: true, isCode: true, isDetail: true))
            }
        }
        return rows
    }

    private static func thunderbolt(_ reading: DeviceReading<ThunderboltReport>) -> [InfoRow] {
        guard let report = reading.value else { return [unreadable] }
        var rows: [InfoRow] = []
        if !report.ports.isEmpty {
            let speeds = Set(report.ports.compactMap(\.speed))
            let speed = speeds.count == 1 ? speeds.first.map { ", \($0.prefix(1).lowercased() + $0.dropFirst()) each" } ?? "" : ""
            rows.append(InfoRow("Ports", "\(report.ports.count)\(speed)"))
            let inUse = report.ports.filter(\.isInUse).count
            rows.append(InfoRow("In use", inUse == 0 ? "None" : "\(inUse) of \(report.ports.count)"))
        }
        for device in report.devices {
            rows.append(InfoRow(device.name, device.speed ?? "", isHeading: true, depth: device.depth))
            if let vendor = device.vendor { rows.append(InfoRow("Maker", vendor, isDetail: true)) }
            rows.append(InfoRow("Connected to", device.upstream ?? "This Mac", isDetail: true))
        }
        return rows
    }

    private static func bluetooth(_ reading: DeviceReading<BluetoothReport>) -> [InfoRow] {
        guard let report = reading.value else { return [unreadable] }
        var rows: [InfoRow] = []
        if let isOn = report.isOn { rows.append(InfoRow("Status", isOn ? "On" : "Off")) }
        if let chipset = report.chipset {
            rows.append(InfoRow("Chipset", chipset + (report.firmware.map { " · firmware \($0)" } ?? "")))
        }
        guard !report.devices.isEmpty else { return rows + [InfoRow("Devices", "None paired")] }
        for device in report.devices {
            let levels = device.batteries.map { ($0.part.map { "\($0) " } ?? "") + "\($0.percent)%" }
            rows.append(InfoRow(device.name, device.isConnected ? "connected" : "not connected", isHeading: true,
                                state: levels.isEmpty ? nil : "battery " + levels.joined(separator: " · ")))
            if let kind = device.kind { rows.append(InfoRow("Kind", kind, isDetail: true)) }
            if let firmware = device.firmware { rows.append(InfoRow("Firmware", firmware, isDetail: true)) }
            if let address = device.address {
                rows.append(InfoRow("Address", address, isSensitive: true, isCode: true, isDetail: true))
            }
        }
        return rows
    }

    private static func audioAndVideo(_ audio: DeviceReading<[AudioDevice]>, _ cameras: DeviceReading<[CameraDevice]>) -> [InfoRow] {
        if audio.value == nil && cameras.value == nil { return [unreadable] }
        var rows: [InfoRow] = []
        for device in audio.value ?? [] {
            let roles = [
                device.isDefaultInput ? "input" : nil, device.isDefaultOutput ? "output" : nil,
                device.isDefaultSystemOutput ? "alerts" : nil,
            ].compactMap { $0 }
            rows.append(InfoRow(device.name, device.transport.map { $0 == "Built-in" ? "built-in" : $0 } ?? "", isHeading: true,
                                state: roles.isEmpty ? nil : "default for " + listed(roles)))
            let channels = [
                device.inputChannels > 0 ? "\(device.inputChannels) in" : nil,
                device.outputChannels > 0 ? "\(device.outputChannels) out" : nil,
            ].compactMap { $0 }
            if !channels.isEmpty { rows.append(InfoRow("Channels", channels.joined(separator: " · "), isDetail: true)) }
            if let rate = device.sampleRate, rate > 0 {
                let kilohertz = rate / 1000
                rows.append(InfoRow("Sample rate", Format.fixed(kilohertz, kilohertz.rounded() == kilohertz ? 0 : 1) + " kHz",
                                    isDetail: true))
            }
            if let maker = device.manufacturer { rows.append(InfoRow("Maker", maker, isDetail: true)) }
        }
        if audio.value == nil { rows.append(InfoRow("Audio", "Couldn't read", status: .unknown)) }
        for camera in cameras.value ?? [] {
            rows.append(InfoRow(camera.name, "camera", isHeading: true))
            if let model = camera.model, model != camera.name { rows.append(InfoRow("Model", model, isDetail: true)) }
        }
        if cameras.value == nil { rows.append(InfoRow("Cameras", "Couldn't read", status: .unknown)) }
        return rows.isEmpty ? [InfoRow("Devices", "None found")] : rows
    }

    /// "input", "input and output", "input, output and alerts".
    private static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
