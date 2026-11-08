import OTMKit
import SwiftUI

/// The static lane is a day's observations. Its neutral stretches are unknown,
/// not continuous running time; no tick or pointer rebuilds the timeline.
struct StartupHistorySection: View {
    let recorder: FlightRecorder?
    let item: LaunchItem
    let refreshID: Date?
    let jobs: LaunchJobStore
    @State private var events: [LaunchHistoryEvent] = []
    @State private var coverage: [LaunchHistoryInterval] = []
    @State private var readAt = Date.now
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.headline)
            if let error {
                Text(error).font(.explanation).foregroundStyle(.secondaryText)
            } else {
                lane
                Text(LaunchHistoryCoverage.caption(coverage, at: readAt))
                    .font(.metadata).foregroundStyle(.secondaryText)
                if let verdict = LaunchHistoryPattern.verdict(events, coverage: coverage, at: readAt) {
                    Text(verdict).font(.explanation).textSelection(.enabled)
                }
                if let restarts = LaunchHistoryPattern.restartSummary(events, at: readAt) {
                    Text(restarts).font(.tableText)
                }
                ForEach(Array(events.filter { $0.kind != .configuration || $0.detail != "Configuration first read" }
                    .suffix(10).reversed())) { event in
                    Text("\(event.words) · \(event.time.formatted(date: .omitted, time: .standard))")
                        .font(.tableText).textSelection(.enabled)
                        .help(help(event))
                }
                if events.isEmpty { Text("No observations stored for this job.").font(.explanation).foregroundStyle(.secondaryText) }
            }
        }
        .task(id: Read(key: LaunchHistoryKey(item), refresh: refreshID)) {
            events = []
            coverage = []
            error = nil
            guard let recorder else { error = "Flight recorder unavailable"; return }
            await jobs.waitForHistoryWrite()
            guard !Task.isCancelled else { return }
            let key = LaunchHistoryKey(item)
            let end = Date.now
            do {
                let stored = try await recorder.launchJobHistory(label: key.label, domain: key.domain,
                                                               from: end.addingTimeInterval(-86_400), to: end)
                guard !Task.isCancelled else { return }
                // Verdicts describe the latest successful read; the tiny stretch
                // after it has no confirming read yet and must not claim a cadence.
                let latest = stored.coverage.last?.end ?? end
                readAt = end.timeIntervalSince(latest) <= LaunchHistoryCoverage.maximumReadGap ? latest : end
                events = stored.events
                coverage = stored.coverage
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Couldn't read history: \(error.localizedDescription)"
            }
        }
    }

    private struct Read: Equatable {
        let key: LaunchHistoryKey
        let refresh: Date?
    }

    private var lane: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary).frame(height: 2)
                ForEach(coverage) { interval in
                    let start = fraction(interval.start) * geometry.size.width
                    let end = fraction(interval.end) * geometry.size.width
                    Rectangle().fill(Color.secondary.opacity(0.55))
                        .frame(width: max(1, end - start), height: 3)
                        .offset(x: start)
                        .help("Watched \(interval.start.formatted(date: .abbreviated, time: .standard)) – "
                              + interval.end.formatted(date: .abbreviated, time: .standard))
                }
                ForEach(events.filter { [.observed, .started, .exited, .failed, .crashed, .restarting].contains($0.kind) }) { event in
                    let fraction = fraction(event.time)
                    Image(systemName: symbol(event))
                        .font(.system(size: 9)).foregroundStyle(tint(event))
                        .offset(x: fraction * max(geometry.size.width - 10, 0))
                        .help(help(event))
                        .accessibilityLabel(help(event))
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 20)
        .accessibilityElement(children: .contain)
    }

    private func fraction(_ date: Date) -> Double {
        max(0, min(1, 1 - readAt.timeIntervalSince(date) / 86_400))
    }

    private func symbol(_ event: LaunchHistoryEvent) -> String {
        switch event.kind {
        case .started: "triangle.fill"
        case .exited: "circle.fill"
        case .observed: "diamond.fill"
        default: "xmark"
        }
    }

    private func tint(_ event: LaunchHistoryEvent) -> Color {
        switch event.kind {
        case .started: Theme.cpu
        case .failed, .crashed, .restarting: LaunchJobHealth.tint
        default: .secondary
        }
    }

    private func help(_ event: LaunchHistoryEvent) -> String {
        let time = event.time.formatted(date: .abbreviated, time: .standard)
        let interval = event.since.map {
            "\nObserved between \($0.formatted(date: .omitted, time: .standard)) and this read; exact time unknown."
        } ?? ""
        return "\(time) · \(event.words)\(interval)"
    }
}

struct StartupFilesSection: View {
    let recorder: FlightRecorder?
    let item: LaunchItem
    let refreshID: Date?
    @State private var checks: [LaunchJobFileCheck] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files now").font(.headline)
            if checks.isEmpty { Text("Checking files…").font(.metadata).foregroundStyle(.secondaryText) }
            ForEach(checks, id: \.label) { check in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(check.label) · \(check.status)").font(.tableText)
                    if let path = check.path {
                        CopyableText(value: path, splitsPath: true).font(.metadata)
                    }
                    if !check.lines.isEmpty {
                        Text(check.lines.joined(separator: "\n"))
                            .font(.metadata.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .task(id: Read(path: item.plistPath, refresh: refreshID)) {
            checks = []
            let selected = item
            let result = await Task.detached(priority: .utility) {
                let current = LaunchJobFiles.currentItem(selected)
                return FileRead(item: current, checks: LaunchJobFiles.check(current ?? selected))
            }.value
            guard !Task.isCancelled else { return }
            checks = result.checks
            if let current = result.item, let recorder {
                try? await recorder.observeLaunchConfiguration(current, at: .now)
            }
        }
    }

    private struct FileRead: Sendable {
        let item: LaunchItem?
        let checks: [LaunchJobFileCheck]
    }

    private struct Read: Equatable {
        let path: String
        let refresh: Date?
    }
}
