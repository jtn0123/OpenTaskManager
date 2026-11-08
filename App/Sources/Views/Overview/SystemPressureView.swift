import OTMKit
import SwiftUI

/// The same observation summary on Overview and in the menu bar popup.
struct SystemPressureSummary: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var showsDetails = LaunchArgument.string("openPressureDetails") == "YES"

    var body: some View {
        if let snapshot = model.snapshot {
            let report = SystemPressureReport(snapshot)
            Button { showsDetails = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: report.findings.isEmpty ? "info.circle" : "waveform.path.ecg")
                        .foregroundStyle(report.findings.isEmpty ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        if !compact { Text("Why is my Mac slow?").fontWeight(.medium) }
                        Text(report.summary)
                            .font(compact ? .callout : .explanation)
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isPaused { Text("Paused readings").font(.explanation).foregroundStyle(.secondaryText) }
                    }
                    Spacer(minLength: 0)
                    if !compact { Text("Details…").font(.callout) } else { Image(systemName: "chevron.right").font(.caption) }
                }
                .contentShape(Rectangle())
                .padding(compact ? 0 : 12)
                .background {
                    if !compact {
                        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035))
                    }
                }
            }
            .buttonStyle(.plain)
            .help("See current resource pressure, readings and the processes using those resources.")
            .sheet(isPresented: $showsDetails) { SystemPressureDetails().samplingDemand(.window) }
        }
    }
}

struct SystemPressureDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @CurrentPage private var page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Why is my Mac slow?").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                if let snapshot = model.snapshot {
                    let report = SystemPressureReport(snapshot)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(report.summary).font(.headline)
                        Text("\(model.isPaused ? "Paused · " : "")Read at \(snapshot.timestamp.formatted(date: .omitted, time: .standard)). "
                             + "These observations cover the latest sampling interval; they don't establish the cause of a slowdown.")
                            .font(.callout).foregroundStyle(.secondaryText)
                        if report.isMeasuring {
                            Text("Collecting a fresh interval after launch, a pause or sleep. CPU and GPU rates need another sample.")
                                .font(.callout)
                        }
                        ForEach(report.findings) { finding in
                            findingCard(finding, snapshot: snapshot)
                        }
                        if report.findings.isEmpty {
                            Text("No high resource pressure was observed in this sample. A brief stall, a waiting app, storage latency "
                                 + "or an external service can still make the Mac feel slow.")
                                .font(.callout)
                        }
                        Divider()
                        readings(snapshot)
                        Text("High disk or network throughput, memory use, and previously allocated swap alone don't prove a bottleneck. "
                             + "Thermal pressure is macOS's state; clock throttling isn't measured. "
                             + "Process rankings cover the processes OTM can read and show usage, not blame.")
                            .font(.callout).foregroundStyle(.secondaryText)
                    }
                    .padding(20)
                }
            }
            .textSelection(.enabled)
        }
        .frame(width: 620, height: 590)
    }

    private func findingCard(_ finding: SystemPressureReport.Finding, snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.title).font(.headline)
            Text(finding.explanation).font(.callout).foregroundStyle(.secondaryText)
            Text(finding.resource == .memory ? "Largest memory footprints now" : finding.resource == .gpu
                 ? "GPU time by process (separate accounting)" : "Highest CPU use now")
                .font(.explanation.weight(.medium)).foregroundStyle(.secondaryText)
            let processes = SystemPressureReport.topProcesses(for: finding.resource, in: snapshot.processes)
            if processes.isEmpty {
                Text("No per-process readings available for this resource.").font(.callout).foregroundStyle(.secondaryText)
            }
            ForEach(processes, id: \.identity) { process in
                Button {
                    guard process.identity.find(in: model.snapshot?.processes ?? []) != nil else { return }
                    model.requestedProcess = process.pid
                    page = .processes
                    dismiss()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Text(model.displayName(for: process)).lineLimit(1)
                        Text("PID \(process.pid)\(process.isRestricted ? " · limited access" : "")")
                            .font(.explanation).foregroundStyle(.secondaryText)
                        Spacer()
                        Text(usage(process, resource: finding.resource)).monospacedDigit()
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this process in Processes")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func readings(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readings and limits").font(.headline)
            LabeledContent("Whole CPU", value: Format.percent(snapshot.cpu.usage))
            LabeledContent("Memory pressure", value: snapshot.memory.pressure.rawValue.capitalized)
            LabeledContent("Thermal pressure", value: snapshot.power.thermalState.rawValue.capitalized)
            LabeledContent("GPU", value: snapshot.gpus.compactMap(\.deviceUtilization).max().map { Format.percent($0) } ?? "Not reported")
            LabeledContent("Swap allocated", value: Format.bytes(snapshot.memory.swapUsed))
            LabeledContent("Swap moving now", value: Format.bytesPerSecond(snapshot.memory.swapInRate + snapshot.memory.swapOutRate))
            Text("High CPU: at least 85% across all cores. One busy core: at least 95% when whole CPU is below 85%. "
                 + "High GPU: at least 90% on a reporting GPU. Memory warning/critical and thermal serious/critical come from macOS.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func usage(_ process: ProcessSample, resource: SystemPressureReport.Resource) -> String {
        switch resource {
        case .memory: Format.bytes(process.memory)
        case .gpu: Format.percent(process.gpuFraction ?? 0)
        case .cpu, .busyCore, .thermal: model.cpuScale.format(process.cpuPercent)
        }
    }
}

private extension SystemPressureReport {
    var summary: String {
        if !findings.isEmpty { return findings.map(\.title).joined(separator: " · ") }
        return isMeasuring ? "Collecting a fresh sample…" : "No high resource pressure observed"
    }
}

private extension SystemPressureReport.Finding {
    var title: String {
        switch resource {
        case .thermal: "Thermal pressure: \(state ?? "unknown")"
        case .memory: "Memory pressure: \(state ?? "unknown")"
        case .cpu: "CPU busy: \(Format.percent(fraction ?? 0))"
        case .busyCore: "One core busy: \(Format.percent(fraction ?? 0))"
        case .gpu: "GPU busy: \(Format.percent(fraction ?? 0))"
        }
    }

    var explanation: String {
        switch resource {
        case .thermal: "macOS reports elevated thermal pressure. CPU use below is context, not an attribution of heat or proof of throttling."
        case .memory: "macOS reports memory pressure. Large footprints show where memory is held, not which app caused the pressure."
        case .cpu: "Most of the whole CPU was busy in this interval. The processes below used the most CPU among those OTM could read."
        case .busyCore: "At least one logical core was nearly fully busy. Work limited to one thread can wait even while other cores are free."
        case .gpu: "A reporting GPU was nearly fully busy. Process GPU time is separate accounting and doesn't add up to device utilization."
        }
    }
}
