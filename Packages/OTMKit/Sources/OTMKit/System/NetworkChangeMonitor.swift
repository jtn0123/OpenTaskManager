import Foundation
import SystemConfiguration
import os

/// The network the Mac uses for the internet, as a flight-recorder event
/// names it: the primary service and its interface, and the address it has.
public struct NetworkInUse: Sendable, Equatable {
    /// "en0"; nil when there's no primary network.
    public let interface: String?
    /// The service's name in System Settings ("Wi-Fi").
    public let service: String?
    /// Its IPv4 address, else its first IPv6 one.
    public let address: String?

    public init(interface: String?, service: String?, address: String?) {
        self.interface = interface
        self.service = service
        self.address = address
    }

    /// Reads it from SCDynamicStore's keys and values, as `NetworkChangeMonitor.patterns` copies them.
    public init(store: [String: Any]) {
        func dictionary(_ key: String) -> [String: Any]? { store[key] as? [String: Any] }
        let global = dictionary("State:/Network/Global/IPv4") ?? dictionary("State:/Network/Global/IPv6")
        let serviceID = global?["PrimaryService"] as? String
        interface = global?["PrimaryInterface"] as? String
        service = serviceID.flatMap { id in
            (dictionary("Setup:/Network/Service/\(id)")?["UserDefinedName"] as? String)
                ?? (dictionary("Setup:/Network/Service/\(id)/Interface")?["UserDefinedName"] as? String)
        }
        let addresses = serviceID.map { id in
            ["IPv4", "IPv6"].flatMap { (dictionary("State:/Network/Service/\(id)/\($0)")?["Addresses"] as? [String]) ?? [] }
        } ?? []
        address = interface == nil ? nil : addresses.first { !$0.isEmpty }
    }

    /// "Wi-Fi (en0)", or just the interface; empty with no network.
    public var label: String {
        guard let interface else { return "" }
        guard let service, service != interface else { return interface }
        return "\(service) (\(interface))"
    }

    /// The event for a change from `old` to this, at `time`: nil when what
    /// a user would notice (the network and its address) is the same.
    public func event(from old: NetworkInUse, at time: Date) -> HistoryEvent? {
        guard self != old else { return nil }
        return HistoryEvent(time: time, kind: .networkChanged, name: label, detail: address ?? "")
    }
}

/// Tells when the network in use changes: the primary service, its
/// interface or its address. SCDynamicStore calls back on the main queue,
/// often several times as one change settles (an address goes, then the
/// new one comes), so the network is read once things have been quiet for
/// `settle` seconds and compared with the last; a change is reported with
/// the time of its first callback. Costs nothing between changes.
@MainActor
public final class NetworkChangeMonitor {
    /// The keys `NetworkInUse` is read from.
    nonisolated public static let patterns = [
        "State:/Network/Global/(IPv4|IPv6)",
        "State:/Network/Service/[^/]+/(IPv4|IPv6)",
        "Setup:/Network/Service/[^/]+(/Interface)?",
    ]
    /// The keys whose change starts a read.
    private static let watched = ["State:/Network/Global/(IPv4|IPv6)", "State:/Network/Service/[^/]+/(IPv4|IPv6)"]
    private static let settle: Duration = .seconds(2)

    // The CF handle never leaves the lock; only Sendable network values do.
    private let store = OSAllocatedUnfairLock<SCDynamicStore?>(uncheckedState: nil)
    private var current: NetworkInUse
    private var changedAt: Date?
    private var reading: Task<Void, Never>?
    private let handler: @MainActor (HistoryEvent) -> Void

    /// Starts watching; `handler` gets each change.
    public init(handler: @escaping @MainActor (HistoryEvent) -> Void) {
        self.handler = handler
        current = NetworkInUse(interface: nil, service: nil, address: nil)
        // The store retains a weak context, so a queued callback cannot use a dead monitor.
        let owner = NetworkChangeContext(monitor: self)
        let watched = Self.watched
        store.withLock { stored in
            var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(owner).toOpaque(), retain: { info in
                return UnsafeRawPointer(Unmanaged<NetworkChangeContext>.fromOpaque(info).retain().toOpaque())
            }, release: { info in
                Unmanaged<NetworkChangeContext>.fromOpaque(info).release()
            }, copyDescription: nil)
            stored = SCDynamicStoreCreate(nil, "OpenTaskManager" as CFString, { _, _, info in
                guard let info else { return }
                let owner = Unmanaged<NetworkChangeContext>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { owner.monitor?.storeChanged() }
            }, &context)
            if let stored {
                SCDynamicStoreSetNotificationKeys(stored, nil, watched as CFArray)
                SCDynamicStoreSetDispatchQueue(stored, .main)
            }
        }
        current = store.withLock { $0.map(Self.read) } ?? current
    }

    deinit {
        store.withLock { stored in
            if let stored { SCDynamicStoreSetDispatchQueue(stored, nil) }
        }
    }

    private func storeChanged() {
        if changedAt == nil { changedAt = Date() }
        reading?.cancel()
        reading = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self, let now = self.store.withLock({ $0.map(Self.read) }) else { return }
            let event = now.event(from: self.current, at: self.changedAt ?? Date())
            self.current = now
            self.changedAt = nil
            if let event { self.handler(event) }
        }
    }

    nonisolated private static func read(_ store: SCDynamicStore) -> NetworkInUse {
        NetworkInUse(store: SCDynamicStoreCopyMultiple(store, nil, Self.patterns as CFArray) as? [String: Any] ?? [:])
    }
}

/// The C callback owns this context, which keeps no monitor alive.
@MainActor
private final class NetworkChangeContext {
    weak var monitor: NetworkChangeMonitor?

    init(monitor: NetworkChangeMonitor) {
        self.monitor = monitor
    }
}
