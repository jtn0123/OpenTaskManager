import OTMKit
import SwiftUI

/// "Internet quality" on a network link's detail: a networkQuality run when
/// asked, its result in plain words, and the last few runs on this link.
/// Its inputs don't change from tick to tick and it reads only
/// `NetworkQualityStore`, so it redraws when a test starts or ends, not per tick.
struct InternetQualityCard: View, Equatable {
    /// The BSD name, "en0".
    let interface: String
    /// "Wi-Fi", "Ethernet".
    let name: String

    private static let available = NetworkQuality.isAvailable

    var body: some View {
        let store = NetworkQualityStore.shared
        let results = store.results(for: interface)
        let run = store.running
        Card(tint: Theme.network) {
            header(run: run, store: store)
            if let run, run.interface == interface {
                SpeedTestRunning(text: "Filling the connection to measure it…", started: run.started,
                                 expected: "about \(Int(NetworkQuality.typicalSeconds)) s")
            } else {
                Text(caption(lastBytes: results.first?.bytesTransferred))
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let run {
                    Text("A test is running on \(run.interface). One test runs at a time.")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                }
            }
            if !Self.available {
                UnavailableNote(text: NetworkQualityError.unavailable.message)
            }
            if let failure = store.failures[interface] {
                SpeedTestFailure(text: failure)
            }
            if let latest = results.first {
                summary(latest)
            }
            if results.count > 1 {
                history(results)
            }
        }
        .task {
            await store.load()
            store.handleLaunchArgument(interface: interface)
        }
    }

    private func header(run: NetworkQualityStore.Run?, store: NetworkQualityStore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Internet quality", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
                .foregroundStyle(Theme.network)
            Spacer(minLength: 8)
            if run?.interface == interface {
                Button("Cancel") { store.cancel() }
                    .help("Stop the test")
            } else {
                Button("Run Test") { store.start(interface: interface) }
                    .disabled(run != nil || !Self.available)
                    .help("Measure \(name)'s Internet speed and responsiveness for about \(Int(NetworkQuality.typicalSeconds)) s")
            }
        }
    }

    /// Said before a test starts: what it measures and what it costs.
    private func caption(lastBytes: UInt64?) -> String {
        let cost = lastBytes.map { " The last test here moved \(Format.bytes($0))." } ?? ""
        return "Measures download and upload capacity, and how responsive the connection stays when full, with macOS's "
            + "networkQuality tool through \(name) (\(interface)). It deliberately loads the connection for about "
            + "\(Int(NetworkQuality.typicalSeconds)) s, which can use a lot of data on a fast line.\(cost)"
    }

    // MARK: - Result

    private func summary(_ result: NetworkQualityResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricStrip(tint: Theme.network) {
                Stat(label: "Download", value: Self.rate(result.downloadBitsPerSecond), color: Theme.network)
                Stat(label: "Upload", value: Self.rate(result.uploadBitsPerSecond), color: Theme.networkSecondary)
                Stat(label: "Responsiveness", value: result.responsiveness.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "—")
                Stat(label: "Idle latency", value: result.idleLatency.map { "\(Format.fixed($0, 0)) ms" } ?? "—")
            }
            if let rpm = result.responsiveness {
                RatingLine(rating: NetworkResponsiveness(rpm: rpm), rpm: rpm)
            }
            Text(Self.details(result))
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// When, through what, against which server, and how the run was set up.
    private static func details(_ result: NetworkQualityResult) -> String {
        var parts = ["Tested \(result.date.formatted(date: .abbreviated, time: .shortened))", result.configurationSummary]
        if let endpoint = result.endpoint { parts.append(endpoint) }
        if let bytes = result.bytesTransferred { parts.append("\(Format.bytes(bytes)) moved") }
        return parts.joined(separator: " · ")
    }

    private static func rate(_ bitsPerSecond: Double?) -> String {
        bitsPerSecond.map { Format.bitsPerSecond($0 / 8) } ?? "—"
    }

    // MARK: - History

    private func history(_ results: [NetworkQualityResult]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent tests on \(interface)").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("When")
                    Text("Download").gridColumnAlignment(.trailing)
                    Text("Upload").gridColumnAlignment(.trailing)
                    Text("Responsiveness")
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                ForEach(results) { result in
                    GridRow {
                        Text(result.date.formatted(date: .abbreviated, time: .shortened))
                        Text(Self.rate(result.downloadBitsPerSecond))
                        Text(Self.rate(result.uploadBitsPerSecond))
                        Text(result.responsiveness.map { "\(Int($0.rounded()).formatted()) RPM · \(NetworkResponsiveness(rpm: $0).title)" } ?? "—")
                    }
                    .font(.tableText)
                    .monospacedDigit()
                    .lineLimit(1)
                }
            }
        }
    }
}

/// The responsiveness rating as a coloured word, what it means, and the
/// delay it stands for.
private struct RatingLine: View {
    private static let colors: [NetworkResponsiveness: Color] = [
        .poor: Theme.data(0.94, 0.33, 0.30),
        .fair: Theme.data(0.96, 0.62, 0.16),
        .good: Theme.data(0.36, 0.76, 0.36),
        .excellent: Theme.data(0.16, 0.72, 0.58),
    ]

    let rating: NetworkResponsiveness
    let rpm: Double

    var body: some View {
        let color = Self.colors[rating] ?? .secondary
        let delay = NetworkResponsiveness.loadedLatency(rpm: rpm).map { " About \(Format.fixed($0, 0)) ms per round trip under load." } ?? ""
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(rating.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.fillShade.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.35)))
            Text(rating.summary + delay)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A running test: a spinner, what's happening, and the time so far.
struct SpeedTestRunning: View {
    var text: String
    var started: Date
    /// How long it usually takes, in words.
    var expected: String
    /// 0...1 when the test knows how far it is.
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if fraction == nil { ProgressView().controlSize(.small) }
                Text(text).font(.callout)
                Spacer(minLength: 8)
                // The system ticks this text over; the view isn't redrawn.
                Text(timerInterval: started...started.addingTimeInterval(24 * 3600), countsDown: false)
                    .monospacedDigit()
                    .font(.callout)
                Text("of \(expected)").font(.metadata).foregroundStyle(.secondaryText)
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1)).tint(Theme.disk)
            }
        }
    }
}

/// Why the last test didn't finish.
struct SpeedTestFailure: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
