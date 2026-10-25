import OTMKit
import SwiftUI

/// Chip-wide power-state activity, independent of the selected GPU and
/// process attribution. Missing counters never become zero-percent bars.
struct MediaEngineCard: View {
    var engines: [MediaEngineSample]

    #if DEBUG
    // Replays an explicitly supplied hardware capture for VM layout checks;
    // only this card changes, so no example readings reach recorded History.
    private static let replay: [MediaEngineSample]? = {
        guard let path = LaunchArgument.string("mediaEngineReplay"),
              let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let samples = try? JSONDecoder().decode([MediaEngineSample].self, from: data),
              samples.allSatisfy({ $0.activeFraction.isFinite && (0...1).contains($0.activeFraction) }) else { return nil }
        return samples
    }()
    #endif

    var body: some View {
        #if DEBUG
        let engines = Self.replay ?? engines
        #endif
        Card(tint: Theme.gpu) {
            HStack {
                Label("Media-engine active time", systemImage: "film")
                    .font(.headline)
                Spacer()
                #if DEBUG
                Text(Self.replay == nil ? "Whole chip" : "Recorded example")
                    .font(.metadata).foregroundStyle(.secondaryText)
                #else
                Text("Whole chip").font(.metadata).foregroundStyle(.secondaryText)
                #endif
            }
            if engines.isEmpty {
                Text("No media-engine activity readings are available. macOS does not publish these counters on every Mac.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            } else {
                FillGrid(minimum: 220, spacing: 12) {
                    ForEach(engines) { engine in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(engine.label).font(.tableText)
                                Spacer()
                                Text(Format.percent(engine.activeFraction, digits: 1))
                                    .font(.tableText).monospacedDigit()
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.gpu.opacity(0.12))
                                    Capsule().fill(Theme.gpu)
                                        .frame(width: proxy.size.width * min(max(engine.activeFraction, 0), 1))
                                }
                            }
                            .frame(height: 5)
                        }
                        .help("IOReport PMP0 · SOC Floor · \(engine.channel)")
                        .accessibilityElement(children: .combine)
                    }
                }
                if !engines.contains(where: { $0.channel.hasPrefix("PRORES") }) {
                    Text("macOS isn’t reporting ProRes activity here.")
                        .font(.explanation).foregroundStyle(.secondaryText)
                }
                Text(MediaEngineSample.explanation + " Channels with no advancing counter are omitted. "
                     + "Measured at most every two seconds, less often in the background.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
        }
        .samplingDemand(.mediaEngines)
    }
}
