import Foundation
import IOKit

/// Reads temperatures, fan speeds and the SMC's DC input rails. It is
/// separate from `SystemMonitor` because the temperature sensors answer slowly
/// (about 50 ms of waiting per pass on an M5 Pro, for under 2 ms of CPU), so
/// the app samples both at once rather than holding up the rest of each tick.
public actor SensorMonitor {
    private let temperatures = HIDTemperatureReader()
    private let smc: SMCSensorReader?

    public init() {
        smc = SMCConnection().map(SMCSensorReader.init)
    }

    public func sample() -> SensorSample {
        SensorSample(temperatures: temperatures?.read() ?? [], fans: smc?.fans() ?? [], rails: smc?.rails() ?? [])
    }
}

/// Temperature sensors published through the HID event system, the same
/// source the system's thermal tools use. The client functions are private
/// IOKit API, looked up at run time like IOReport's, so a Mac or VM without
/// them simply reports no temperatures.
final class HIDTemperatureReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`; its level field is the type shifted into the high half.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private struct Sensor {
        let name: String
        let service: AnyObject
    }

    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    /// Kept alive for as long as its services are read.
    private let client: AnyObject
    private let sensors: [Sensor]

    init?() {
        // IOKit is already linked; this only resolves the private symbols.
        let process = UnsafeMutableRawPointer(bitPattern: -2)
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(process, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createClient = load("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = load("IOHIDEventGetFloatValue", as: FloatValue.self),
              let client = createClient(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Apple's vendor usage page, temperature sensor usage.
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        // Only keep the sensors the app shows; each read is a round trip.
        sensors = services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  SensorModel.classify(name) != nil else { return nil }
            return Sensor(name: name, service: service)
        }
        guard !sensors.isEmpty else { return nil }
        self.client = client
        self.copyEvent = copyEvent
        self.floatValue = floatValue
    }

    func read() -> [SensorSample.Temperature] {
        let readings = sensors.compactMap { sensor -> (name: String, celsius: Double)? in
            guard let event = copyEvent(sensor.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return (sensor.name, floatValue(event, Self.temperatureField))
        }
        return SensorModel.temperatures(from: readings)
    }
}

/// Fan speeds and rails from the SMC. Fans: `FNum` fans, each with its
/// actual (`F0Ac`), minimum (`F0Mn`) and maximum (`F0Mx`) speed in rpm.
/// Rails: the keys in `SMCRail`, each one kernel call a tick once the SMC has
/// said it has the key, and none after it has said it hasn't.
final class SMCSensorReader {
    private let smc: SMCConnection
    private let fanCount: Int

    init(smc: SMCConnection) {
        self.smc = smc
        let count = smc.double("FNum").map { Int($0) } ?? (smc.double("F0Ac") != nil ? 1 : 0)
        fanCount = min(max(count, 0), 8)
    }

    func fans() -> [SensorSample.Fan] {
        (0..<fanCount).compactMap { index in
            guard let rpm = smc.double("F\(index)Ac"), rpm.isFinite, rpm >= 0 else { return nil }
            return SensorSample.Fan(id: index, rpm: rpm, minimumRPM: smc.double("F\(index)Mn"), maximumRPM: smc.double("F\(index)Mx"))
        }
    }

    func rails() -> [SensorSample.Rail] {
        SMCRail.keys.compactMap { SMCRail.rail(key: $0.key, label: $0.label, unit: $0.unit, value: smc.double($0.key)) }
    }
}
