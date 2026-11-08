import AppKit
import OTMKit
import SwiftUI

/// Spike captures for the app. While "Capture spikes automatically" is on,
/// each update goes through a `SpikeRecorder` (a fixed ring and a few
/// comparisons, the only work on the main actor); a finished capture is
/// written off the main actor, as a recording file in
/// `SpikeCaptureLibrary`'s folder, with a spike event in the flight
/// recorder. History's Spikes list reads the folder, and opens a capture
/// through `HistoryRecordingStore` like any recording.
///
/// Off until the user turns it on: it writes files nobody asked for, each
/// naming the busiest processes, and the flight recorder's ten-second
/// records already cover most slowdowns. Off, an update costs one Bool.
@Observable
@MainActor
final class SpikeCaptureStore {
    static let shared = SpikeCaptureStore()
    static let enabledKey = "captureSpikes"
    /// When the list was last opened: captures since then are new.
    static let seenKey = "spikesSeen"
    /// Two copies of the app catch the same spike within this many seconds of each other.
    static let duplicateWindow: TimeInterval = 120

    /// Whether updates are watched for spikes.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            watching = isEnabled || forced != nil
            if !isEnabled {
                recorder.reset()
                capturing = nil
                debugCapture = false
            }
        }
    }

    /// The saved captures, newest first; nil until first read.
    private(set) var captures: [SpikeCaptureEntry]?
    /// The kind a capture under way is about.
    private(set) var capturing: SpikeKind?
    /// Captures that began after the list was last opened.
    private(set) var unseen = 0

    @ObservationIgnored let library: SpikeCaptureLibrary
    @ObservationIgnored private var recorder = SpikeRecorder()
    /// `isEnabled`, read once an update without going through observation.
    @ObservationIgnored private var watching: Bool
    /// A debug build's `-captureSpikeNow <kind>`: forced after this many updates.
    @ObservationIgnored private var forced: (kind: SpikeKind, updates: Int)?
    /// A forced capture is under way: updates are watched until it's
    /// handed off, even with the setting off.
    @ObservationIgnored private var debugCapture = false
    /// Captures are written one after another.
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(library: SpikeCaptureLibrary = SpikeCaptureLibrary()) {
        self.library = library
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        var request: (kind: SpikeKind, updates: Int)?
        #if DEBUG
        if let kind = LaunchArgument.string("captureSpikeNow").flatMap(SpikeKind.init) { request = (kind, 15) }
        #endif
        isEnabled = enabled
        forced = request
        watching = enabled || request != nil
    }

    // MARK: - Updates

    /// Takes one update: its flight-recorder figures, worked out already,
    /// and the snapshot for the pressure levels and process list. `history`
    /// is the live flight recorder, which gets a spike event per trigger.
    func add(_ values: HistoryValues, snapshot: SystemSnapshot, history: FlightRecorder?) {
        guard watching else { return }
        if let request = forced {
            if request.updates <= 1 {
                // Ten seconds on, so a debug capture is quick to wait for.
                recorder.force(request.kind, after: 10)
                forced = nil
                debugCapture = true
            } else {
                forced = (request.kind, request.updates - 1)
            }
        }
        let sample = SpikeSample(values, pressure: snapshot.memory.pressure, thermal: snapshot.power.thermalState,
                                 interval: snapshot.interval, at: snapshot.timestamp)
        let capture = recorder.add(sample, processes: snapshot.processes, logicalCores: snapshot.cpu.coreUsage.count)
        let now = recorder.capturing
        if now != capturing { capturing = now }
        if let capture { write(capture, history: history) }
        if debugCapture, now == nil {
            // The forced capture is handed off; with the setting off, nothing more is watched.
            debugCapture = false
            watching = isEnabled
            if !watching { recorder.reset() }
        }
    }

    /// Writes a capture off the main actor, unless another copy of the app
    /// already saved the same spike, then reads the list again.
    private func write(_ capture: SpikeCapture, history: FlightRecorder?) {
        let library = library
        let generator = Self.generator
        let window = Self.duplicateWindow
        let previous = writing
        writing = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            let primary = capture.triggers[0]
            guard !library.hasCapture(of: primary.kind, near: primary.time, within: window) else { return }
            try? await history?.append(capture.triggers.map(\.event))
            let events = (try? await history?.events(from: capture.start, to: capture.end)) ?? []
            let file = capture.recording(machine: RecordingMachine.current(), generator: generator, exported: Date(), events: events)
            guard (try? library.save(file)) != nil else { return }
            let entries = library.entries()
            await self?.show(entries)
        }
    }

    // MARK: - The list

    /// Reads the folder again, off the main actor.
    func refresh() {
        let library = library
        reading?.cancel()
        reading = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) { library.entries() }.value
            guard !Task.isCancelled else { return }
            self?.show(entries)
        }
    }

    private func show(_ entries: [SpikeCaptureEntry]) {
        if entries != captures { captures = entries }
        let seen = UserDefaults.standard.object(forKey: Self.seenKey) as? Date ?? .distantPast
        let count = entries.filter { $0.session.start > seen }.count
        if count != unseen { unseen = count }
    }

    /// The list was opened: what's in it is no longer new.
    func markSeen() {
        let newest = captures?.map(\.session.start).max() ?? Date()
        UserDefaults.standard.set(max(newest, Date()), forKey: Self.seenKey)
        if unseen != 0 { unseen = 0 }
    }

    func open(_ entry: SpikeCaptureEntry) {
        HistoryRecordingStore.shared.open(entry.url)
    }

    func reveal(_ entry: SpikeCaptureEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.directory)
    }

    /// Moves a capture to the Trash.
    func delete(_ entry: SpikeCaptureEntry) {
        do {
            try library.delete(entry.url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "“\(entry.url.lastPathComponent)” couldn't be moved to the Trash"
            alert.runModal()
        }
        refresh()
    }

    private static var generator: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces)
    }
}
