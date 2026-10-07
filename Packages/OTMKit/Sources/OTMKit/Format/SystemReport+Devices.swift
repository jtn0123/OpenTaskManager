import Foundation

/// The System page's attached-device cards: USB, Thunderbolt, Bluetooth,
/// and audio and video. Each device is a heading with its facts under it.
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

    private static func usb(_ reading: DeviceReading<USBReport>) -> [InfoRow] {
        guard let report = reading.value else { return [unreadable] }
        guard !report.devices.isEmpty else {
            return [InfoRow("Devices", report.buses == 0 ? "No USB buses found" : "None connected")]
        }
        var rows: [InfoRow] = []
        for device in report.devices {
            rows.append(InfoRow(device.name, [device.speed, device.isBuiltIn ? "built-in" : nil].compactMap { $0 }.joined(separator: ", "),
                                isHeading: true))
            if let vendor = device.vendor { rows.append(InfoRow("Maker", vendor)) }
            // The hub it hangs off keeps the tree readable in a flat list.
            rows.append(InfoRow("Connected to", device.hub ?? device.bus))
            if let power = device.power { rows.append(InfoRow("Power", power)) }
            if let ids = device.idPair { rows.append(InfoRow("Vendor:product", ids, isCode: true)) }
            if let serial = device.serialNumber { rows.append(InfoRow("Serial number", serial, isSensitive: true, isCode: true)) }
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
            rows.append(InfoRow(device.name, device.vendor ?? "", isHeading: true))
            if let speed = device.speed { rows.append(InfoRow("Link", speed)) }
            rows.append(InfoRow("Connected to", device.upstream ?? "This Mac"))
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
            rows.append(InfoRow(device.name, device.isConnected ? "connected" : "not connected", isHeading: true))
            if let kind = device.kind { rows.append(InfoRow("Kind", kind)) }
            if !device.batteries.isEmpty {
                let levels = device.batteries.map { ($0.part.map { "\($0) " } ?? "") + "\($0.percent)%" }
                rows.append(InfoRow("Battery", levels.joined(separator: " · ")))
            }
            if let firmware = device.firmware { rows.append(InfoRow("Firmware", firmware)) }
            if let address = device.address { rows.append(InfoRow("Address", address, isSensitive: true, isCode: true)) }
        }
        return rows
    }

    private static func audioAndVideo(_ audio: DeviceReading<[AudioDevice]>, _ cameras: DeviceReading<[CameraDevice]>) -> [InfoRow] {
        if audio.value == nil && cameras.value == nil { return [unreadable] }
        var rows: [InfoRow] = []
        for device in audio.value ?? [] {
            rows.append(InfoRow(device.name, device.transport.map { $0 == "Built-in" ? "built-in" : $0 } ?? "", isHeading: true))
            let channels = [
                device.inputChannels > 0 ? "\(device.inputChannels) in" : nil,
                device.outputChannels > 0 ? "\(device.outputChannels) out" : nil,
            ].compactMap { $0 }
            if !channels.isEmpty { rows.append(InfoRow("Channels", channels.joined(separator: " · "))) }
            if let rate = device.sampleRate, rate > 0 {
                let kilohertz = rate / 1000
                rows.append(InfoRow("Sample rate", Format.fixed(kilohertz, kilohertz.rounded() == kilohertz ? 0 : 1) + " kHz"))
            }
            let defaults = [
                device.isDefaultInput ? "input" : nil, device.isDefaultOutput ? "output" : nil,
                device.isDefaultSystemOutput ? "alerts" : nil,
            ].compactMap { $0 }
            if !defaults.isEmpty {
                let text = defaults.joined(separator: ", ")
                rows.append(InfoRow("Default for", text.prefix(1).uppercased() + text.dropFirst()))
            }
            if let maker = device.manufacturer { rows.append(InfoRow("Maker", maker)) }
        }
        if audio.value == nil { rows.append(InfoRow("Audio", "Couldn't read", status: .unknown)) }
        for camera in cameras.value ?? [] {
            rows.append(InfoRow(camera.name, "camera", isHeading: true))
            if let model = camera.model, model != camera.name { rows.append(InfoRow("Model", model)) }
        }
        if cameras.value == nil { rows.append(InfoRow("Cameras", "Couldn't read", status: .unknown)) }
        return rows.isEmpty ? [InfoRow("Devices", "None found")] : rows
    }
}
