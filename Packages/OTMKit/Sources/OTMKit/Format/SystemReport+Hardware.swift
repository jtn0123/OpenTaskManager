import Foundation

/// The rows `HardwareInventory` adds to the System page: the memory's type
/// and maker on the Memory card (and slots, on a Mac that has them), each
/// drive's controller and health on the Storage card, and the Controllers
/// and Readers card. A fact macOS didn't report says so on its own row;
/// nothing is filled in from the chip's name. Serial numbers and card
/// tokens are sensitive rows.
extension SystemReport {
    static let checking = "Checking…"

    // MARK: - Memory

    /// Type and manufacturer as reported, then slots where there are any.
    static func memoryDetails(_ hardware: HardwareInventory?) -> [InfoRow] {
        guard let hardware else { return [InfoRow("Type", checking), InfoRow("Manufacturer", checking)] }
        guard let memory = hardware.memory.value else {
            return [InfoRow("Type", "Couldn't read", status: .unknown), InfoRow("Manufacturer", "Couldn't read", status: .unknown)]
        }
        var rows = [
            InfoRow("Type", memory.reportedType ?? "Not reported"),
            InfoRow("Manufacturer", memory.reportedManufacturer ?? "Not reported"),
        ]
        if let upgradeable = memory.isUpgradeable { rows.append(InfoRow("Upgradeable", upgradeable ? "Yes" : "No")) }
        if let ecc = memory.ecc { rows.append(InfoRow("ECC", ecc, status: ecc == "Errors" ? .warning : nil)) }
        guard !memory.modules.isEmpty else { return rows }
        let filled = memory.modules.filter { !$0.isEmpty }
        rows.append(InfoRow("Slots", "\(filled.count) of \(memory.modules.count) in use"))
        let lines = memory.modules.map { module -> String in
            guard !module.isEmpty else { return "\(module.slot): empty" }
            var facts = [module.size, module.type, module.speed].compactMap { $0 }.joined(separator: " ")
            if let maker = module.manufacturer { facts += (facts.isEmpty ? "" : ", ") + maker }
            if let part = module.partNumber { facts += " " + part }
            if let status = module.status, status != "OK" { facts += " (\(status))" }
            return "\(module.slot): " + (facts.isEmpty ? "details not reported" : facts)
        }
        rows.append(InfoRow("Modules", lines.joined(separator: "\n"),
                            status: memory.modules.contains { $0.status == "Mapped Out" } ? .warning : nil))
        let serials = filled.compactMap { module in module.serialNumber.map { "\(module.slot): \($0)" } }
        if !serials.isEmpty {
            rows.append(InfoRow("Serial numbers", serials.joined(separator: "\n"), isSensitive: true, isCode: true))
        }
        return rows
    }

    // MARK: - Drives

    /// "Apple Fabric, internal", "USB, external"; "Internal, bus not
    /// reported" for a drive whose driver names no interconnect.
    static func connection(_ disk: DiskInfo) -> String? {
        let location = disk.interconnectLocation?.lowercased()
        switch (disk.interconnect, location) {
        case let (bus?, place?): return "\(bus), \(place)"
        case let (bus?, nil): return bus
        case let (nil, place?): return place.prefix(1).uppercased() + place.dropFirst() + ", bus not reported"
        case (nil, nil): return nil
        }
    }

    /// The drive's controller, SMART status, TRIM, firmware and serial
    /// number, where `system_profiler` lists it.
    static func driveDetails(_ bsdName: String, hardware: HardwareInventory?) -> [InfoRow] {
        guard let (controller, drive) = hardware?.drive(bsdName: bsdName) else { return [] }
        var rows = [InfoRow("Controller", "\(controller.name) (\(controller.bus.title))")]
        if let smart = drive.smartStatus {
            rows.append(InfoRow("SMART status", smart, status: drive.isVerified == true ? .good : .warning))
        }
        if let trim = drive.supportsTRIM { rows.append(InfoRow("TRIM", trim ? "Supported" : "Not supported")) }
        if let revision = drive.revision { rows.append(InfoRow("Firmware", revision)) }
        if let serial = drive.serialNumber { rows.append(InfoRow("Serial number", serial, isSensitive: true, isCode: true)) }
        return rows
    }

    // MARK: - Controllers and readers

    /// Storage controllers with their drives, then the SD card reader, then
    /// smart cards.
    static func controllers(_ hardware: HardwareInventory?) -> [InfoRow] {
        guard let hardware else { return [InfoRow("Controllers", checking)] }
        var rows = storageControllerRows(hardware.storageControllers)
        rows += cardReaderRows(hardware.cardReaders)
        rows += smartCardRows(hardware.smartCards)
        return rows
    }

    private static func storageControllerRows(_ reading: DeviceReading<[StorageController]>) -> [InfoRow] {
        guard let controllers = reading.value else { return [InfoRow("Storage controllers", "Couldn't read", status: .unknown)] }
        guard !controllers.isEmpty else { return [InfoRow("Storage controllers", "None reported")] }
        var rows: [InfoRow] = []
        for controller in controllers {
            rows.append(InfoRow(controller.name, "\(controller.bus.title) storage", isHeading: true))
            if let vendor = controller.vendor { rows.append(InfoRow("Vendor", vendor)) }
            if let link = controller.link { rows.append(InfoRow("Link", link)) }
            let drives = controller.drives.map { drive in
                let size = drive.sizeBytes.map { ", " + SystemFacts.decimalBytes($0) } ?? ""
                return (drive.model ?? drive.name) + (drive.bsdName.map { " (\($0))" } ?? "") + size
            }
            rows.append(InfoRow(drives.count == 1 ? "Drive" : "Drives", drives.isEmpty ? "None" : drives.joined(separator: "\n")))
        }
        return rows
    }

    private static func cardReaderRows(_ reading: DeviceReading<[CardReader]>) -> [InfoRow] {
        guard let readers = reading.value else {
            return [InfoRow("SD card reader", "", isHeading: true), InfoRow("Reader", "Couldn't read", status: .unknown)]
        }
        guard !readers.isEmpty else { return [InfoRow("SD card reader", "", isHeading: true), InfoRow("Reader", "None")] }
        var rows: [InfoRow] = []
        for reader in readers {
            rows.append(InfoRow("SD card reader", reader.isBuiltIn ? "built-in" : "external", isHeading: true))
            if reader.cards.isEmpty {
                rows.append(InfoRow("Card", "None inserted"))
            }
            for card in reader.cards {
                let size = card.sizeBytes.map { ", " + SystemFacts.decimalBytes($0) } ?? ""
                rows.append(InfoRow("Card", card.name + (card.productName.map { " (\($0))" } ?? "") + size))
                if let serial = card.serialNumber { rows.append(InfoRow("Card serial", serial, isSensitive: true, isCode: true)) }
            }
            if let vendor = reader.vendorID, let device = reader.deviceID {
                rows.append(InfoRow("PCI vendor:device", "\(hexDigits(vendor)):\(hexDigits(device))", isCode: true))
            }
        }
        return rows
    }

    /// "0x17a0" reads "17a0".
    private static func hexDigits(_ text: String) -> String {
        text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
    }

    private static func smartCardRows(_ reading: DeviceReading<SmartCardReport>) -> [InfoRow] {
        var rows = [InfoRow("Smart cards", "", isHeading: true)]
        guard let report = reading.value else { return rows + [InfoRow("Readers", "Couldn't read", status: .unknown)] }
        let readers = report.readers.map { $0.name + ($0.hasCard ? " (card in)" : "") }
        rows.append(InfoRow("Readers", readers.isEmpty ? "None connected" : readers.joined(separator: "\n")))
        // A reader no driver has taken doesn't reach CryptoTokenKit, so more
        // smart-card devices on USB than readers means one is waiting for one.
        if let usb = report.usbDevices, usb.count > report.readers.count {
            rows.append(InfoRow("On USB", usb.joined(separator: "\n")))
        }
        let kinds = report.tokens.map(SmartCardReport.tokenKind)
        rows.append(InfoRow("Cards present", kinds.isEmpty ? "None" : "\(kinds.count) (\(Array(Set(kinds)).sorted().joined(separator: ", ")))"))
        if !report.tokens.isEmpty {
            rows.append(InfoRow("Card tokens", report.tokens.joined(separator: "\n"), isSensitive: true, isCode: true))
        }
        func drivers(_ list: [SmartCardReport.Driver]) -> String {
            list.isEmpty ? "None" : list.map { $0.id + ($0.version.map { " \($0)" } ?? "") }.joined(separator: "\n")
        }
        rows.append(InfoRow("Reader drivers", drivers(report.readerDrivers), isCode: !report.readerDrivers.isEmpty))
        rows.append(InfoRow("Card drivers", drivers(report.tokenDrivers), isCode: !report.tokenDrivers.isEmpty))
        return rows
    }
}
