import OTMKit
import SwiftUI

/// Plays the History page's timeline back: moves the pinned moment from
/// point to point at 1×, 10× or 60× the recording's pace, crossing gaps in
/// one jump (`HistoryPlayback` in OTMKit picks each step). Only the scrubber
/// changes as it plays, so the charts never redraw, and the pinned moment
/// moves at most twice a second.
@Observable
@MainActor
final class HistoryPlayer {
    private(set) var isPlaying = false
    /// How many times the recording's own pace.
    var speed: Double = 10
    /// While the next step jumps a gap: the seconds that weren't recorded.
    private(set) var gap: TimeInterval?
    /// The points shown, kept current by the page.
    @ObservationIgnored var points: [HistoryPoint] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var scrubber: HistoryScrubber?

    /// Plays on from the pinned moment, or from the start when none is
    /// pinned or it's the last; through `session` alone when one is given.
    /// Pinning another moment meanwhile carries on from there; unpinning
    /// (Esc, or Return to latest) stops.
    func play(_ scrubber: HistoryScrubber, within session: RecordingSession? = nil) {
        stop()
        let shown = playable(session)
        guard let first = shown.first?.time, let last = shown.last?.time else { return }
        var current = scrubber.pinned
        if let pinned = current, pinned < first || pinned >= last { current = nil }
        self.scrubber = scrubber
        isPlaying = true
        scrubber.isPlaying = true
        task = Task {
            // The pinned moment as playback last left it, to tell when the user moves it.
            var expected = scrubber.pinned
            while let step = HistoryPlayback.step(after: current, in: playable(session), speed: speed) {
                // Set only when it changes: every set redraws the transport.
                if gap != step.gap { gap = step.gap }
                try? await Task.sleep(for: .seconds(step.delay))
                guard !Task.isCancelled else { return }
                if gap != nil { gap = nil }
                if scrubber.pinned != expected {
                    guard let moved = scrubber.pinned else { break }
                    current = moved
                    expected = moved
                    continue
                }
                scrubber.pinned = step.time
                current = step.time
                expected = step.time
            }
            finish()
        }
    }

    func stop() {
        task?.cancel()
        finish()
    }

    private func finish() {
        task = nil
        if isPlaying { isPlaying = false }
        if gap != nil { gap = nil }
        if scrubber?.isPlaying == true { scrubber?.isPlaying = false }
    }

    private func playable(_ session: RecordingSession?) -> [HistoryPoint] {
        guard let session else { return points }
        return points.filter { session.contains($0.time) }
    }
}

/// The row under the rail: marking a session, and what to do with the one
/// picked, on the left; playback on the right.
struct HistoryTimelineControls: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer
    let store: HistoryRecordingStore
    /// The live recording, where sessions are saved; nil for a recording file.
    let recorder: FlightRecorder?
    /// Seconds each point averages.
    let bucket: TimeInterval

    @State private var note = ""

    var body: some View {
        let naming = scrubber.draft?.end != nil
        HStack(spacing: 8) {
            if let recorder {
                sessionControls(recorder)
            } else {
                Label("Read-only recording", systemImage: "lock")
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Naming a session takes the row.
            if !naming {
                HistoryTransport(scrubber: scrubber, player: player)
            }
        }
        .controlSize(.small)
        .frame(minHeight: 22)
    }

    @ViewBuilder private func sessionControls(_ recorder: FlightRecorder) -> some View {
        if let draft = scrubber.draft {
            if let end = draft.end {
                Text(HistorySessionStyle.span(draft.start, end))
                    .font(.metadata.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .fixedSize()
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80, maxWidth: 240)
                    .onSubmit { save(in: recorder) }
                Button("Save Session") { save(in: recorder) }
                    .buttonStyle(.borderedProminent)
                    .tint(HistorySessionStyle.tint)
                    .fixedSize()
                Button("Cancel", action: cancel).fixedSize()
            } else {
                Text("Session from \(HistoryMoment.label(draft.from, bucket: bucket))")
                    .font(.metadata.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                Button("Mark End") { scrubber.draft?.to = scrubber.pinned ?? .now }
                    .fixedSize()
                    .help("End the session at the pinned moment, or now if none is pinned")
                Button("Cancel", action: cancel).fixedSize()
            }
        } else if let session = scrubber.session {
            Image(systemName: "bookmark.fill").foregroundStyle(HistorySessionStyle.tint)
            (Text(HistorySessionStyle.title(session)).fontWeight(.medium)
                + Text("  " + HistorySessionStyle.span(session.start, session.end)).foregroundStyle(.secondaryText))
                .font(.callout)
                .lineLimit(1)
                .layoutPriority(-1)
                .help("\(HistorySessionStyle.title(session)), \(HistorySessionStyle.span(session.start, session.end))")
            Button("Export…") { Task { await store.export(session, from: recorder) } }
                .fixedSize()
                .help("Save this session as a recording file, to open later or on another Mac")
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(session, from: recorder)
                    if scrubber.session?.id == session.id { scrubber.session = nil }
                }
            }
            .fixedSize()
            .help("Forget this session. Its records stay until they age out after 7 days.")
            Button("Done") { scrubber.session = nil }
                .fixedSize()
        } else {
            Button {
                scrubber.session = nil
                scrubber.draft = HistorySessionDraft(from: scrubber.pinned ?? .now, bucket: bucket)
            } label: {
                Label("Mark Start", systemImage: "flag")
            }
            .fixedSize()
            .help("Start a session at the pinned moment, or now if none is pinned")
            ViewThatFits(in: .horizontal) {
                Text("then Mark End, or Shift-drag along the timeline")
                Text("or Shift-drag the timeline")
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.metadata)
            .foregroundStyle(.secondaryText)
        }
    }

    private func save(in recorder: FlightRecorder) {
        guard let draft = scrubber.draft, let end = draft.end else { return }
        let text = note
        Task {
            guard let session = await store.save(from: draft.start, to: end, note: text, in: recorder) else { return }
            scrubber.draft = nil
            scrubber.session = session
            note = ""
        }
    }

    private func cancel() {
        scrubber.draft = nil
        note = ""
    }
}

/// Play or pause, the speed, and a word while playback jumps a gap.
private struct HistoryTransport: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer

    var body: some View {
        HStack(spacing: 8) {
            if let gap = player.gap {
                Text("Jumping \(Format.roughDuration(gap)) not recorded")
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            Button {
                if player.isPlaying {
                    player.stop()
                } else {
                    player.play(scrubber, within: scrubber.session)
                }
            } label: {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 52)
            }
            .fixedSize()
            .help(player.isPlaying ? "Stop playback, keeping the moment it reached pinned"
                : "Play the timeline back from the pinned moment (or the picked session), skipping what wasn't recorded")
            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.speed = $0 })) {
                ForEach(HistoryPlayback.speeds, id: \.self) { speed in
                    Text("\(Int(speed))×").tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Playback speed: at 60×, a minute of the recording plays in a second")
        }
    }
}
