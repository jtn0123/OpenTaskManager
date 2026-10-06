import Darwin
import Foundation

/// One IOReport channel's change over a sampling interval, copied out of the
/// library's CF dictionaries into plain values.
struct IOReportChannel: Equatable {
    struct State: Equatable {
        let name: String
        /// Time spent in the state, in the channel's unit (24 MHz ticks for
        /// performance states).
        let residency: Int64
    }

    enum Value: Equatable {
        case integer(Int64)
        case states([State])
    }

    let group: String
    let subgroup: String
    let name: String
    let unit: String
    /// Registry entry ID of the driver that publishes the channel. For GPU
    /// channels this is the `IOAccelerator`'s ID.
    let driverID: UInt64
    let value: Value
}

/// libIOReport's C entry points. It's a private system library with no
/// headers or module map, so it's opened at run time and `init` fails where
/// it's missing (Intel Macs before it shipped, stripped-down VMs).
final class IOReportLibrary {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
    ) -> Unmanaged<CFTypeRef>?
    typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelInteger = @convention(c) (CFDictionary) -> Int32
    typealias IndexedInteger = @convention(c) (CFDictionary, Int32) -> Int64
    typealias IndexedString = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    /// IOReportChannelGetFormat values this code reads.
    enum Format: Int32 {
        case simple = 1
        case state = 2
    }

    let copyChannelsInGroup: CopyChannelsInGroup
    let mergeChannels: MergeChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let group: ChannelString
    let subgroup: ChannelString
    let channelName: ChannelString
    let unitLabel: ChannelString
    let format: ChannelInteger
    let simpleIntegerValue: IndexedInteger
    let stateCount: ChannelInteger
    let stateName: IndexedString
    let stateResidency: IndexedInteger

    private let handle: UnsafeMutableRawPointer

    init?(path: String = "/usr/lib/libIOReport.dylib") {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannelsInGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let mergeChannels = load("IOReportMergeChannels", as: MergeChannels.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let group = load("IOReportChannelGetGroup", as: ChannelString.self),
              let subgroup = load("IOReportChannelGetSubGroup", as: ChannelString.self),
              let channelName = load("IOReportChannelGetChannelName", as: ChannelString.self),
              let unitLabel = load("IOReportChannelGetUnitLabel", as: ChannelString.self),
              let format = load("IOReportChannelGetFormat", as: ChannelInteger.self),
              let simpleIntegerValue = load("IOReportSimpleGetIntegerValue", as: IndexedInteger.self),
              let stateCount = load("IOReportStateGetCount", as: ChannelInteger.self),
              let stateName = load("IOReportStateGetNameForIndex", as: IndexedString.self),
              let stateResidency = load("IOReportStateGetResidency", as: IndexedInteger.self) else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.copyChannelsInGroup = copyChannelsInGroup
        self.mergeChannels = mergeChannels
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.group = group
        self.subgroup = subgroup
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.format = format
        self.simpleIntegerValue = simpleIntegerValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }

    deinit {
        dlclose(handle)
    }

    /// The "Get" accessors follow the CF get rule: the string isn't ours to release.
    func string(_ accessor: ChannelString, _ channel: CFDictionary) -> String {
        accessor(channel)?.takeUnretainedValue() as String? ?? ""
    }
}

/// A live IOReport subscription to a fixed set of channels. Creating one
/// costs a few milliseconds, so make it once and call `sample()` each tick.
final class IOReportSubscription {
    /// The key under which channel dictionaries and samples list their channels.
    private static let channelsKey = "IOReportChannels"

    private let library: IOReportLibrary
    private var subscription: CFTypeRef?
    private var subscribedChannels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: ContinuousClock.Instant?

    /// Subscribes to the channels of each (group, subgroup) pair for which
    /// `keep(group, channelName)` is true; a nil subgroup means the whole group.
    /// Fails when no channel survives, so callers can treat IOReport as missing.
    init?(library: IOReportLibrary, groups: [(group: String, subgroup: String?)], keep: (String, String) -> Bool) {
        self.library = library
        var merged: CFMutableDictionary?
        for (group, subgroup) in groups {
            guard let channels = library.copyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?
                .takeRetainedValue() else { continue }
            if let merged {
                library.mergeChannels(merged, channels, nil)
            } else {
                merged = channels
            }
        }
        guard let merged else { return nil }

        // Every channel a subscription covers adds to the cost of each
        // sample, so drop the ones that aren't needed.
        let dictionary = merged as NSMutableDictionary
        guard let all = dictionary[Self.channelsKey] as? [NSDictionary] else { return nil }
        let kept = all.filter { channel in
            let channel = channel as CFDictionary
            return keep(library.string(library.group, channel), library.string(library.channelName, channel))
        }
        guard !kept.isEmpty else { return nil }
        dictionary[Self.channelsKey] = kept

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = library.createSubscription(nil, merged, &subscribed, 0, nil)?.takeRetainedValue(),
              let subscribed = subscribed?.takeRetainedValue() else { return nil }
        self.subscription = subscription
        subscribedChannels = subscribed
    }

    deinit {
        // Release IOReport's objects while the library is still loaded.
        previous = nil
        subscribedChannels = nil
        subscription = nil
    }

    /// Each channel's change since the previous call, and the seconds between
    /// the two readings. nil on the first call, which only sets the baseline.
    func sample() -> (interval: Double, channels: [IOReportChannel])? {
        guard let subscription, let subscribedChannels,
              let current = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            return nil
        }
        let now = ContinuousClock.now
        defer {
            previous = current
            previousTime = now
        }
        guard let previous, let previousTime,
              let delta = library.createSamplesDelta(previous, current, nil)?.takeRetainedValue() else {
            return nil
        }
        let elapsed = now - previousTime
        let interval = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (interval, channels(in: delta))
    }

    private func channels(in sample: CFDictionary) -> [IOReportChannel] {
        guard let entries = (sample as NSDictionary)[Self.channelsKey] as? [NSDictionary] else { return [] }
        return entries.compactMap { entry in
            let channel = entry as CFDictionary
            let value: IOReportChannel.Value
            switch IOReportLibrary.Format(rawValue: library.format(channel)) {
            case .simple:
                value = .integer(library.simpleIntegerValue(channel, 0))
            case .state:
                let count = max(library.stateCount(channel), 0)
                value = .states((0..<count).map { index in
                    IOReportChannel.State(
                        name: library.stateName(channel, index)?.takeUnretainedValue() as String? ?? "",
                        residency: library.stateResidency(channel, index)
                    )
                })
            case nil:
                return nil
            }
            return IOReportChannel(
                group: library.string(library.group, channel),
                subgroup: library.string(library.subgroup, channel),
                name: library.string(library.channelName, channel),
                unit: library.string(library.unitLabel, channel),
                driverID: (entry["DriverID"] as? NSNumber)?.uint64Value ?? 0,
                value: value
            )
        }
    }
}
