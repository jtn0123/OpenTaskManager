import AppKit
import OTMKit
import Observation

/// The Apps page's state: the scan, bundle sizes as they're measured, and
/// which apps are running.
///
/// The scan runs once when the page opens and on Refresh. Sizes follow,
/// a few bundles at a time off the main actor, and arrive in batches so the
/// table redraws a few times a second at most. Running apps update when
/// NSWorkspace reports a launch or quit. Nothing here follows the sampling
/// tick, so the page costs nothing once it's settled.
@MainActor
@Observable
final class InstalledAppStore {
    private(set) var apps: [InstalledApp]?
    private(set) var sizes: [InstalledApp.ID: UInt64] = [:]
    private(set) var running: [InstalledApp.ID: [Int32]] = [:]
    private(set) var scannedAt: Date?
    private(set) var isScanning = false
    /// Bundles still waiting to be measured.
    private(set) var sizesLeft = 0

    /// How many bundles are walked at once. Walking is disk-bound, so more
    /// threads mostly add contention.
    nonisolated static let sizeWidth = 3

    /// Sizes outlive the page, keyed by bundle and version, so coming back to
    /// it doesn't walk every bundle again. Refresh clears them.
    private static var sizeCache: [InstalledApp.ID: (version: String, bytes: UInt64)] = [:]

    func scan(refresh: Bool) async {
        if refresh { Self.sizeCache.removeAll() }
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        isScanning = false
        guard !Task.isCancelled else { return }
        apps = scanned
        scannedAt = .now
        sizes = sizes.filter { id, _ in scanned.contains { $0.id == id } }
        updateRunning()
    }

    /// Measures every bundle whose size isn't cached, until done or cancelled.
    func measureSizes() async {
        guard let apps else { return }
        var known: [InstalledApp.ID: UInt64] = [:]
        var jobs: [SizeJob] = []
        for app in apps {
            if let cached = Self.sizeCache[app.id], cached.version == app.versionText {
                known[app.id] = cached.bytes
            } else {
                jobs.append(SizeJob(id: app.id, path: app.resolvedPath))
            }
        }
        sizes = known
        sizesLeft = jobs.count
        guard !jobs.isEmpty else { return }

        let versions = Dictionary(apps.map { ($0.id, $0.versionText) }, uniquingKeysWith: { first, _ in first })
        var batch: [InstalledApp.ID: UInt64] = [:]
        var flushed = ContinuousClock.now
        func flush() {
            sizes.merge(batch) { _, new in new }
            sizesLeft -= batch.count
            for (id, bytes) in batch { Self.sizeCache[id] = (versions[id] ?? "", bytes) }
            batch.removeAll()
            flushed = .now
        }
        for await result in Self.measure(jobs) {
            // Cancelled by Refresh or by leaving the page: drop what's left,
            // so a stale size can't land after Refresh cleared the cache.
            guard !Task.isCancelled else { return }
            batch[result.id] = result.bytes
            if ContinuousClock.now - flushed > .milliseconds(250) { flush() }
        }
        guard !Task.isCancelled else { return }
        flush()
        // Bundles that couldn't be read never report; don't leave them "measuring".
        sizesLeft = 0
    }

    /// Matches NSWorkspace's running apps to the installed ones.
    func updateRunning() {
        guard let apps else { return }
        let references = NSWorkspace.shared.runningApplications.map {
            RunningAppReference(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path, bundleIdentifier: $0.bundleIdentifier)
        }
        let matched = InstalledApps.runningPIDs(of: apps, running: references)
        if matched != running { running = matched }
    }

    /// Keeps `running` current while the page is open. NSWorkspace reports
    /// each launch and quit through key-value observing, so nothing polls.
    func followRunningApps() async {
        let observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.updateRunning() }
        }
        defer { observation.invalidate() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: Measuring

    struct SizeJob: Sendable {
        let id: InstalledApp.ID
        let path: String
    }

    struct SizeResult: Sendable {
        let id: InstalledApp.ID
        let bytes: UInt64
    }

    /// Walks the bundles on a few GCD threads (the walk blocks, so it stays
    /// off Swift's cooperative pool) and streams each size as it's found.
    /// Ending the stream, as leaving the page does, stops the walk.
    private nonisolated static func measure(_ jobs: [SizeJob]) -> AsyncStream<SizeResult> {
        AsyncStream { continuation in
            let stop = CancellationFlag()
            continuation.onTermination = { _ in stop.set() }
            let measure: @Sendable (SizeJob) -> Void = { job in
                if let bytes = InstalledApps.allocatedSize(ofBundleAt: job.path, isCancelled: { stop.isSet }) {
                    continuation.yield(SizeResult(id: job.id, bytes: bytes))
                }
            }
            DispatchQueue.global(qos: .utility).async {
                BoundedWork.forEach(jobs, width: sizeWidth, isCancelled: { stop.isSet }, measure)
                continuation.finish()
            }
        }
    }
}
