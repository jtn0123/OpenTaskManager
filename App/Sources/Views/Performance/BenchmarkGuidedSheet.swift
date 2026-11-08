import OTMKit
import SwiftUI

/// Only this sheet watches published samples. Closing it cancels its task.
struct BenchmarkGuidedSheet: View {
    let targets: BenchmarkWorkspace.SuiteTargets
    let initialSelection: String
    @Environment(\.dismiss) private var dismiss
    @State private var selection = "all"
    @State private var repeatCount = BenchmarkSessionProtocol.repeats
    @State private var settling = BenchmarkSettling(started: Date())
    @State private var preflight = BenchmarkSettling(started: Date()).snapshot(now: Date())
    @State private var progress = BenchmarkSettling(started: .distantPast).status(now: .distantPast).progress
    @State private var waitUntil = BenchmarkSettling.defaultWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Guided benchmark run").font(.title2.weight(.semibold))
            Picker("Tests", selection: $selection) {
                Text("CPU").tag("cpu")
                Text("GPU").tag("gpu")
                Text("All ticked tests").tag("all")
            }
            .pickerStyle(.segmented)
            Stepper("\(repeatCount) measured repeats", value: $repeatCount, in: BenchmarkSessionProtocol.repeatRange)
            Text("One warm-up pass is discarded, then \(repeatCount) measured passes run one test at a time. "
                + "A quiet start helps comparisons; these conditions do not establish the cause of a result.")
                .font(.explanation).foregroundStyle(.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(preflight.rows) { row in
                    Label(row.text, systemImage: row.quiet ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(row.quiet ? AnyShapeStyle(.primary) : AnyShapeStyle(BenchmarkLook.caution))
                        .font(.tableText)
                }
            }
            Text(preflight.verdict).font(.headline)
            Text(progress)
                .font(.metadata).monospacedDigit().foregroundStyle(.secondaryText)
            if let latest = preflight.readings.last {
                Text("Latest sample: \(latest.date.formatted(date: .omitted, time: .standard))")
                    .font(.metadata).foregroundStyle(.secondaryText)
            }
            if GuidedBenchmarkFixture.enabled {
                Text("Made-up readings and sessions for screenshots; nothing is run or saved.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Wait") { waitUntil = min(waitUntil + 30, BenchmarkSettling.maximumWait) }
                    .disabled(waitUntil >= BenchmarkSettling.maximumWait || preflight.elapsed < waitUntil)
                Button(preflight.settled ? "Proceed" : "Proceed anyway") { proceed() }
                    .disabled(BenchmarkHistories.anyRunning || BenchmarkWorkspace.shared.suiteRunning || GuidedBenchmarkFixture.enabled)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { selection = initialSelection }
        .task(id: waitUntil) {
            if GuidedBenchmarkFixture.enabled {
                settling = GuidedBenchmarkFixture.watch(battery: true)
                let now = settling.started.addingTimeInterval(30)
                preflight = settling.snapshot(now: now)
                progress = settling.status(now: now).progress
                return
            }
            repeat {
                if let reading = BenchmarkContextFeed.preflightReading(after: settling.readings.last?.date) { settling.append(reading) }
                let now = Date()
                preflight = settling.snapshot(now: now)
                progress = settling.status(now: now).progress
                if preflight.elapsed >= BenchmarkSettling.maximumWait { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func proceed() {
        if let reading = BenchmarkContextFeed.preflightReading(after: settling.readings.last?.date) { settling.append(reading) }
        let start = settling.snapshot(now: Date())
        var kinds = BenchmarkSessionProtocol.kinds(selection) ?? [.cpu, .gpu]
        let workspace = BenchmarkWorkspace.shared
        if selection == "all" {
            if workspace.includesDisk, targets.disk != nil, targets.diskTarget != nil { kinds.append(.disk) }
            if workspace.includesNetwork, targets.interface != nil { kinds.append(.network) }
        }
        workspace.runGuided(kinds: kinds, targets: targets, preflight: start, repeatCount: repeatCount)
        dismiss()
    }
}
