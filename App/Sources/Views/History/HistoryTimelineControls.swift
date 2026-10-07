import OTMKit
import SwiftUI

/// Plays the History page's timeline back: moves the scrubber's playhead
/// from point to point at 1×, 10× or 60× the recording's pace, crossing gaps
/// in one jump (`HistoryPlayback` in OTMKit picks each step). Only the
/// scrubber changes as it plays, so the charts never redraw, and the
/// playhead moves at most twice a second. A moment pinned meanwhile is held
/// apart from it, and the playhead stays where it paused.
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

    /// Plays from the pinned moment (the pin becomes the playhead), else on
    /// from where the playhead paused, else from the start; through
    /// `session` alone when one is given. Moving the playhead on the rail
    /// meanwhile carries on from there.
    func play(_ scrubber: HistoryScrubber, within session: RecordingSession? = nil) {
        pause()
        let shown = playable(session)
        guard !shown.isEmpty else { return }
        var current = HistoryPlayback.start(playhead: scrubber.playhead, pinned: scrubber.pinned, in: shown)
        scrubber.pin(nil)
        if let current, scrubber.playhead != current { scrubber.playhead = current }
        self.scrubber = scrubber
        isPlaying = true
        scrubber.isPlaying = true
        task = Task {
            // The playhead as playback last left it, to tell when the user moves it.
            var expected = scrubber.playhead
            while let step = HistoryPlayback.step(after: current, in: playable(session), speed: speed) {
                // Set only when it changes: every set redraws the transport.
                if gap != step.gap { gap = step.gap }
                try? await Task.sleep(for: .seconds(step.delay))
                guard !Task.isCancelled else { return }
                if gap != nil { gap = nil }
                if scrubber.playhead != expected {
                    guard let moved = scrubber.playhead else { break }
                    current = moved
                    expected = moved
                    continue
                }
                scrubber.playhead = step.time
                current = step.time
                expected = step.time
            }
            finish()
            // Played to the very end: the panel goes back to it. The end of a
            // session keeps the playhead there, paused.
            if let current, current == points.last?.time, scrubber.playhead == current { scrubber.playhead = nil }
        }
    }

    /// Stops playback, keeping the playhead where it reached.
    func pause() {
        task?.cancel()
        finish()
    }

    /// Stops playback and puts the playhead away, back to the latest or the end.
    func stop(_ scrubber: HistoryScrubber) {
        pause()
        if scrubber.playhead != nil { scrubber.playhead = nil }
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
                Button("Mark End") { scrubber.draft?.to = scrubber.picked ?? .now }
                    .fixedSize()
                    .help("End the session at the pinned moment, else where playback is, else now")
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
                scrubber.draft = HistorySessionDraft(from: scrubber.picked ?? .now, bucket: bucket)
            } label: {
                Label("Mark Start", systemImage: "flag")
            }
            .fixedSize()
            .help("Start a session at the pinned moment, else where playback is, else now")
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
            HistoryPlayButton(scrubber: scrubber, player: player)
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

/// Play, Pause, or Resume where playback paused. For a recording file,
/// replay is what the page is for, so it's the prominent button, in the
/// replay's tint. A view of its own, as it reads the playhead: each step
/// redraws it and not the speed picker.
private struct HistoryPlayButton: View {
    let scrubber: HistoryScrubber
    let player: HistoryPlayer

    var body: some View {
        if scrubber.showsFile {
            button
                .buttonStyle(.borderedProminent)
                .tint(HistorySessionStyle.tint)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            if player.isPlaying {
                player.pause()
            } else {
                player.play(scrubber, within: scrubber.session)
            }
        } label: {
            Label(player.isPlaying ? "Pause" : scrubber.playhead != nil ? "Resume" : "Play",
                  systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 52)
        }
        .fixedSize()
        .help(player.isPlaying ? "Pause playback where it is (the toolbar's Pause stops live updates instead)"
            : "Play the timeline back from the pinned moment, else where it paused (or the picked session), skipping what wasn't recorded")
    }
}
