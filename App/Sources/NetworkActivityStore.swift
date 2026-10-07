import AppKit
import Observation
import OTMKit

/// Which apps and processes are using the network, read with `nettop` on its
/// own slow cadence.
///
/// A reading costs nettop about 20 ms of CPU, too much for the main
/// sampler's tick, so it runs off the main actor every few seconds and only
/// while a view that shows it is on screen. Each such view runs `track` from
/// its `.task`; the store samples while at least one of them is tracking and
/// stops when SwiftUI cancels the last. Overview and Performance share it, so
/// moving between them keeps the graphs.
@Observable
@MainActor
final class NetworkActivityStore {
    static let refreshInterval: Duration = .seconds(3)
    static var refreshSeconds: TimeInterval { refreshInterval / .seconds(1) }
    /// Readings across the graphs: three minutes.
    static let graphSpan = 60
    /// Started again after a longer gap than this, the graphs begin afresh
    /// instead of joining old readings to new ones.
    private static let staleAfter: Duration = .seconds(10)

    struct Identity {
        let name: String
        let icon: NSImage
    }

    /// Traffic by app with its helpers folded in, keyed by the app's PID.
    private(set) var apps = NetworkActivityHistory<Int32>(capacity: graphSpan + 2)
    /// Traffic by process, keyed by PID.
    private(set) var processes = NetworkActivityHistory<Int32>(capacity: graphSpan + 2)
    /// Names and icons for every PID in either history. A process that quits
    /// keeps its name until its traffic scrolls out of the graphs.
    private(set) var identities: [Int32: Identity] = [:]
    /// True once two readings have given the first rates.
    private(set) var hasMeasured = false
    /// True when nettop couldn't run.
    private(set) var isUnavailable = false

    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var lastReading: ContinuousClock.Instant?

    /// Keeps the store sampling until the calling task is cancelled.
    func track(model: AppModel) async {
        consumers += 1
        start(model)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        consumers -= 1
        if consumers == 0 { stop() }
    }

    func identity(_ pid: Int32) -> Identity {
        identities[pid] ?? Identity(name: "PID \(pid)", icon: IconCache.generic)
    }

    private func start(_ model: AppModel) {
        guard sampling == nil else { return }
        if let lastReading, ContinuousClock.now - lastReading > Self.staleAfter { reset() }
        sampling = Task { [weak self, weak model] in
            var baseline: (traffic: [Int32: ProcessTraffic], time: ContinuousClock.Instant)?
            while !Task.isCancelled {
                guard let model else { return }
                if model.isPaused {
                    // Frozen like the other pages. The first reading after
                    // resuming is a new baseline, not a rate across the pause.
                    baseline = nil
                } else {
                    let traffic = await Task.detached(priority: .utility) { ProcessNetwork.read(excludingLoopback: true) }.value
                    let now = ContinuousClock.now
                    guard let self, !Task.isCancelled else { return }
                    if isUnavailable != (traffic == nil) { isUnavailable = traffic == nil }
                    if let traffic, let previous = baseline {
                        ingest(ProcessNetwork.rates(from: previous.traffic, to: traffic, interval: (now - previous.time) / .seconds(1)),
                               model: model)
                    }
                    baseline = traffic.map { ($0, now) }
                }
                // The first rates come a second after the first reading, so a
                // page that just opened isn't left waiting.
                let quick = baseline != nil && self?.hasMeasured == false
                try? await Task.sleep(for: quick ? .seconds(1) : Self.refreshInterval)
            }
        }
    }

    private func stop() {
        sampling?.cancel()
        sampling = nil
    }

    private func reset() {
        apps.removeAll()
        processes.removeAll()
        identities = [:]
        hasMeasured = false
    }

    private func ingest(_ rates: [ProcessNetworkRate], model: AppModel) {
        // Group the way the process list does, and take names and icons from
        // the main sampler's latest snapshot, so an app reads "Safari" rather
        // than nettop's short executable name.
        apps.append(NetworkGrouping.byApp(rates, owners: NetworkGrouping.owners(model.appGroups)))
        processes.append(NetworkGrouping.byProcess(rates))
        var sampled: [Int32: ProcessSample] = [:]
        for process in model.snapshot?.processes ?? [] { sampled[process.pid] = process }
        var nettopNames: [Int32: String] = [:]
        for rate in rates { nettopNames[rate.pid] = rate.name }
        var named: [Int32: Identity] = [:]
        for pid in Set(apps.totals.keys).union(processes.totals.keys) {
            if let process = sampled[pid] {
                named[pid] = Identity(name: model.displayName(for: process), icon: IconCache.icon(for: process, app: model.regularApps[pid]))
            } else if let known = identities[pid] {
                named[pid] = known
            } else if let name = nettopNames[pid] {
                named[pid] = Identity(name: name, icon: IconCache.generic)
            }
        }
        identities = named
        hasMeasured = true
        lastReading = .now
    }
}
