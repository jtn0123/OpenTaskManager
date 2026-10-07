import AppKit
import OTMKit
import SwiftUI
import UniformTypeIdentifiers

/// Recording sessions and recording files for the History page: the
/// sessions saved in the live recording, and the file opened in their place,
/// if any. One for the app, so the File menu and a double-clicked file reach
/// the page.
@Observable
@MainActor
final class HistoryRecordingStore {
    static let shared = HistoryRecordingStore()

    /// A recording file, `.otmrecording`, declared in the app's Info.plist.
    static let contentType = UTType(exportedAs: RecordingFile.format, conformingTo: .json)

    /// The recording file on show instead of the live history.
    private(set) var opened: OpenedRecording?
    /// The sessions saved in the live recording, oldest first.
    private(set) var sessions: [RecordingSession] = []
    /// How the recording file's replay is going while the History page shows
    /// it, for the toolbar; nil on the live history and on every other page.
    private(set) var replay: HistoryReplayStatus?

    @ObservationIgnored private var launchSpeed: Double?
    @ObservationIgnored private var handledLaunchArguments = false

    /// The sessions as the page last read them; only a change redraws what shows them.
    func update(_ sessions: [RecordingSession]) {
        if sessions != self.sessions { self.sessions = sessions }
    }

    /// The replay's state as the page last saw it; only a change redraws the toolbar.
    func report(_ replay: HistoryReplayStatus?) {
        if replay != self.replay { self.replay = replay }
    }

    // MARK: - Recording files

    /// Asks for a recording file and shows it.
    func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a recording saved from OpenTaskManager's History page."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Reads a recording file off the main actor and shows it on the History page.
    func open(_ url: URL) {
        UserDefaults.standard.set(Page.history.rawValue, forKey: "page")
        Task {
            do {
                opened = try await Task.detached(priority: .userInitiated) { try OpenedRecording.read(url) }.value
            } catch {
                Self.alert("“\(url.lastPathComponent)” couldn't be opened", error.localizedDescription)
            }
        }
    }

    /// Back to the live history.
    func close() {
        opened = nil
    }

    // MARK: - Sessions

    /// Saves a session in the live recording.
    func save(from start: Date, to end: Date, note: String, in recorder: FlightRecorder) async -> RecordingSession? {
        do {
            let session = try await recorder.addSession(from: start, to: end, note: note)
            update((try? await recorder.sessions()) ?? sessions + [session])
            return session
        } catch {
            Self.alert("The session couldn't be saved", error.localizedDescription)
            return nil
        }
    }

    func delete(_ session: RecordingSession, from recorder: FlightRecorder) async {
        do {
            try await recorder.deleteSession(session.id)
            update((try? await recorder.sessions()) ?? sessions.filter { $0.id != session.id })
        } catch {
            Self.alert("The session couldn't be deleted", error.localizedDescription)
        }
    }

    /// Saves `session`'s records as a recording file, where the user picks.
    func export(_ session: RecordingSession, from recorder: FlightRecorder) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: session)
        panel.message = "A recording holds this stretch's figures, the names of the busiest apps, "
            + "and this Mac's model, chip, memory and macOS version."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let generator = Self.generator
        do {
            let file = try await recorder.recording(of: session, machine: RecordingMachine.current(), generator: generator)
            try await Task.detached(priority: .userInitiated) { try file.encoded().write(to: url, options: .atomic) }.value
        } catch {
            Self.alert("The recording couldn't be saved", error.localizedDescription)
        }
    }

    // MARK: - Launch arguments

    /// `-openRecording <path>` opens a recording file at launch, and
    /// `-openPlayback 1|10|60` plays it back at that speed once it shows.
    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        if let speed = LaunchArgument.string("openPlayback").flatMap(Double.init), HistoryPlayback.speeds.contains(speed) {
            launchSpeed = speed
        }
        if let path = LaunchArgument.string("openRecording") {
            open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }

    /// The playback speed asked for at launch, once.
    func takeLaunchSpeed() -> Double? {
        defer { launchSpeed = nil }
        return launchSpeed
    }

    // MARK: - Helpers

    private static var generator: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces)
    }

    /// "OpenTaskManager Build spike 2026-10-07 1002.otmrecording".
    private static func fileName(for session: RecordingSession) -> String {
        let note = session.note.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stamp = session.start.formatted(.iso8601.year().month().day()) + " "
            + session.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        return ["OpenTaskManager", note, stamp].filter { !$0.isEmpty }.joined(separator: " ") + "." + RecordingFile.fileExtension
    }

    private static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A recording file read for the History page: its session, the Mac it
/// came from, and its records in an in-memory `FlightRecorder`, so the page
/// reads it like the live recording.
struct OpenedRecording: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let session: RecordingSession
    let machine: RecordingMachine
    let generator: String
    let exported: Date
    let records: Int
    let reported: [RecordingFigure: Bool]
    let recorder: FlightRecorder

    /// The session's note, else the file's name.
    var title: String {
        session.note.isEmpty ? url.deletingPathExtension().lastPathComponent : session.note
    }

    /// Figures the recording's Mac didn't report, as opposed to reporting zero.
    var notReported: [String] {
        var names: [String] = []
        if reported[.gpu] == false { names.append("GPU") }
        if reported[.systemWatts] == false { names.append("power") }
        if reported[.chipCelsius] == false { names.append("chip temperature") }
        return names
    }

    static func read(_ url: URL) throws -> OpenedRecording {
        let file = try RecordingFile.decode(Data(contentsOf: url))
        return OpenedRecording(url: url, session: file.session, machine: file.machine, generator: file.generator,
                               exported: file.exported, records: file.records.count, reported: file.reported,
                               recorder: try FlightRecorder(replaying: file, from: url))
    }
}

/// Over the History page while a recording file shows: which recording,
/// from which Mac, and the way back to the live history.
struct HistoryRecordingBanner: View {
    let recording: OpenedRecording
    let store: HistoryRecordingStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(HistorySessionStyle.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording: \(recording.title)")
                    .font(.headline)
                    .lineLimit(1)
                Text(details)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                // Two lines in a narrow window, so what wasn't reported still shows.
                Text(machine)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
            }
            .help("\(recording.url.path)\n\(details)\n\(machine)")
            Spacer(minLength: 8)
            Button("Back to Live History") { store.close() }
                .fixedSize()
                .help("Close this recording and show this Mac's own history again")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(HistorySessionStyle.tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// "Wed, Oct 7 10:02 – 10:17 AM · 15 min · 91 records · read-only".
    private var details: String {
        let session = recording.session
        return [HistorySessionStyle.span(session.start, session.end, dated: true), Format.roughDuration(session.duration),
                "\(recording.records) records", "read-only"].joined(separator: " · ")
    }

    /// "Recorded on MacBook Pro · Apple M3 Pro · 36 GB · macOS 27.2 · GPU not reported".
    private var machine: String {
        let missing = recording.notReported
        return "Recorded on \(recording.machine.summary)"
            + (missing.isEmpty ? "" : " · \(ListFormatter.localizedString(byJoining: missing)) not reported")
    }
}

/// The toolbar's Recordings menu: open a recording file, or go back to the
/// live history; export the range shown; and the saved sessions, each to
/// show, export or delete.
struct HistoryRecordingsMenu: View {
    let store: HistoryRecordingStore
    let scrubber: HistoryScrubber
    /// The live recording; nil if it couldn't be opened.
    let recorder: FlightRecorder?
    /// The range shown.
    let domain: ClosedRange<Date>
    /// Picks a session on the timeline.
    let show: (RecordingSession) -> Void

    var body: some View {
        Menu {
            Button("Open Recording…") { store.chooseRecording() }
            if store.opened != nil {
                Button("Back to Live History") { store.close() }
            } else if let recorder {
                Button("Export Shown Range as Recording…") {
                    let shown = RecordingSession(start: domain.lowerBound, end: domain.upperBound)
                    Task { await store.export(shown, from: recorder) }
                }
                if !store.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(store.sessions.reversed()) { session in
                            Menu("\(HistorySessionStyle.title(session))  \(HistorySessionStyle.span(session.start, session.end))") {
                                Button("Show on Timeline") { show(session) }
                                Button("Export Recording…") { Task { await store.export(session, from: recorder) } }
                                Divider()
                                Button("Delete Session", role: .destructive) {
                                    Task {
                                        await store.delete(session, from: recorder)
                                        if scrubber.session?.id == session.id { scrubber.session = nil }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Recordings", systemImage: "record.circle")
        }
        .help("Open a recording file, or save a session as one")
    }
}

/// How a recording file's replay is going: playing at which speed, or paused.
struct HistoryReplayStatus: Equatable {
    let isPlaying: Bool
    /// How many times the recording's own pace.
    let speed: Double

    /// "Replay · 10×", or "Replay paused": the recording's name is the
    /// page banner's to give.
    var label: String {
        isPlaying ? "Replay · \(Int(speed))×" : "Replay paused"
    }
}

/// Tells the toolbar how replay is going while the History page shows a
/// recording file, and that it's over once the file closes or the page goes.
/// It alone reads the player's state, so play and pause redraw nothing else.
struct HistoryReplayReporter: View {
    let player: HistoryPlayer
    let store: HistoryRecordingStore
    /// Showing a recording file rather than the live history.
    let showsFile: Bool

    var body: some View {
        let status = showsFile ? HistoryReplayStatus(isPlaying: player.isPlaying, speed: player.speed) : nil
        Color.clear
            .onChange(of: status, initial: true) { store.report(status) }
            .onDisappear { store.report(nil) }
    }
}

/// The toolbar's word on a recording file's replay, after the collecting
/// badge while the History page shows one, in the replay's tint: so replay
/// never reads as this Mac's live figures. Which recording, and that it's
/// read-only, is the page banner's to say.
struct HistoryReplayBadge: View {
    let status: HistoryReplayStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HistorySessionStyle.tint)
            Text(status.label)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(HistorySessionStyle.tint.opacity(0.15), in: Capsule())
        .fixedSize()
        .help(status.isPlaying ? "The History page is replaying the recording named in its banner at \(Int(status.speed))× its own pace"
            : "The History page shows the recording named in its banner, its replay paused. Play it from the timeline.")
    }
}
