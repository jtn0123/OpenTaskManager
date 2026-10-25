import OTMKit
import SwiftUI

/// "Speed test" on a disk's detail: pick a volume or folder, and a test
/// on its own thread writes, reads back and checks one temporary file, then
/// deletes it. Shows MB/s and IOPS for each phase as it finishes; the last
/// few results for the volume fold away under Saved runs, beside a link to
/// compare them in the Benchmarks workspace. Its inputs don't change from tick to
/// tick and it reads only `DiskSpeedStore`, so it redraws with the test's
/// progress, not per tick. What the test writes stays in a line over the
/// figures; how it measures folds away under Methodology.
struct DiskSpeedCard: View, Equatable {
    /// The BSD name, "disk0".
    let disk: String
    let volumes: [DiskSpeedVolumeChoice]
    /// Bumped by the shortcut beside the detail's title: the card rings for a
    /// moment and Run Test takes the keyboard focus. Nothing starts.
    let reveal: Int
    @FocusState private var runFocused: Bool

    /// Reads first, the figures people compare.
    private static let order: [DiskSpeedPhase] = [.sequentialRead, .sequentialWrite, .randomRead, .randomWrite]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.disk == rhs.disk && lhs.volumes == rhs.volumes && lhs.reveal == rhs.reveal
    }

    var body: some View {
        let store = DiskSpeedStore.shared
        let target = store.target(disk: disk, volumes: volumes)
        let run = store.running
        let here = run?.disk == disk ? run : nil
        let results = target.map { store.results(for: $0) } ?? []
        Card(tint: Theme.disk) {
            header(run: run, here: here, target: target, store: store)
            picker(target: target, store: store, running: run != nil)
            if let here {
                let progress = store.progress
                SpeedTestRunning(text: progress.map { "\($0.phase.title)…" } ?? "Starting…", started: here.started,
                                 expected: "usually 10–30 s", fraction: progress?.fraction ?? 0)
                tiles(result: nil, progress: progress)
            } else {
                Text(summary)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let run {
                    Text("A test is running on \(run.target.title). One test runs at a time.")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                }
                if let failure = store.failures[disk] {
                    SpeedTestFailure(text: failure)
                }
                if let latest = results.first {
                    tiles(result: latest, progress: nil)
                    // What this volume did that flatters the figures stays beside them.
                    Text((["Tested \(latest.date.formatted(date: .abbreviated, time: .shortened)) on \(latest.volume.name)."]
                            + DiskSpeedTest.cautions(latest)).joined(separator: " "))
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if results.count > 1 {
                SavedRunsDisclosure(kind: .disk, runs: results.map(BenchmarkRun.init),
                                    place: "on \(results.first?.volume.name ?? target?.title ?? "this volume")")
                    .equatable()
            }
            MethodologyDisclosure(preview: "1 MB blocks in sequence, then 4K blocks at random, in one checked file") {
                Text(caption)
                if let latest = results.first {
                    Text(DiskSpeedTest.fileLevelNote(latest))
                }
            }
        }
        .modifier(SpeedTestReveal(reveal: reveal))
        .onChange(of: reveal) { runFocused = true }
        .task(id: target) {
            await store.load()
            let current = store.target(disk: disk, volumes: volumes)
            if let current { store.resolveVolume(of: current.path) }
            store.handleLaunchArgument(disk: disk, target: current)
        }
    }

    /// Over the figures: what running the test does to the folder.
    private var summary: String {
        "Writes a temporary file of up to \(Format.wholeBytes(DiskSpeedConfiguration.defaultFileSize)) there, reads it back, "
            + "then deletes it."
    }

    private var caption: String {
        "Writes a temporary file of up to \(Format.wholeBytes(DiskSpeedConfiguration.defaultFileSize)) (at most a tenth of the free "
            + "space), reads it back and checks it, then deletes it, even if cancelled. 1 MB blocks in sequence, "
            + "then 4K blocks at random places for 3 s each."
    }

    private func header(run: DiskSpeedStore.Run?, here: DiskSpeedStore.Run?, target: DiskSpeedTarget?,
                        store: DiskSpeedStore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Speed test", systemImage: "speedometer")
                .font(.headline)
                .foregroundStyle(Theme.disk)
            Spacer(minLength: 8)
            if here != nil {
                Button("Cancel") { store.cancel() }
                    .help("Stop the test and delete its file")
            } else {
                Button("Run Test") {
                    if let target { store.start(disk: disk, target: target) }
                }
                .disabled(run != nil || target == nil)
                .focused($runFocused)
                .help(target.map { "Measure read and write speed in \($0.title) (\($0.subtitle))" } ?? "Choose a folder to test first")
            }
        }
    }

    /// Where the test file goes: the home volume, another volume on this
    /// disk, or any folder.
    private func picker(target: DiskSpeedTarget?, store: DiskSpeedStore, running: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Test in").font(.callout).foregroundStyle(.secondaryText)
            Menu {
                ForEach(store.targets(disk: disk, volumes: volumes)) { option in
                    Button {
                        store.pick(option, disk: disk)
                    } label: {
                        Label("\(option.title) — \(option.subtitle)", systemImage: option == target ? "checkmark" : option.symbol)
                    }
                }
                Divider()
                Button {
                    store.chooseFolder(disk: disk)
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label(target.map { "\($0.title) — \($0.subtitle)" } ?? "Choose a folder", systemImage: target?.symbol ?? "folder")
            }
            .fixedSize()
            .disabled(running)
            .help("Choose the volume or folder to test")
        }
    }

    // MARK: - Figures

    /// A tile per phase: figures once it's done, the speed so far while it
    /// runs, a dash until then.
    private func tiles(result: DiskSpeedResult?, progress: DiskSpeedProgress?) -> some View {
        FillGrid(minimum: 130, spacing: 10) {
            ForEach(Self.order, id: \.self) { phase in
                if let measurement = result?.measurement(phase) ?? progress?.finished[phase] {
                    SpeedTile(title: phase.title, value: Format.megabytesPerSecond(measurement.bytesPerSecond),
                              detail: Format.operationsPerSecond(measurement.operationsPerSecond))
                } else if let progress, progress.phase == phase {
                    SpeedTile(title: phase.title, value: Format.megabytesPerSecond(progress.bytesPerSecond),
                              detail: "measuring…", provisional: true)
                } else {
                    SpeedTile(title: phase.title, value: "—", detail: progress == nil ? " " : "waiting", provisional: true)
                }
            }
        }
    }

}

/// One phase's figures: MB/s large, IOPS under it.
private struct SpeedTile: View {
    var title: String
    var value: String
    var detail: String
    /// Not a final figure yet.
    var provisional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(provisional ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
            Text(detail).font(.callout).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.disk.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.disk.opacity(0.22)))
        .accessibilityElement(children: .combine)
    }
}
