import OTMKit
import SwiftUI

struct GPUTimeScalePicker: View {
    @Setting(Settings.gpuTimeGraphScale) private var scale: CPUGraphScale
    var body: some View {
        Picker("GPU time scale", selection: $scale) {
            Text("Auto").tag(CPUGraphScale.auto)
            Text("100%").tag(CPUGraphScale.full)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Auto fits GPU-time graphs to the activity shown; 100% keeps the top fixed at one second of GPU time per elapsed second")
    }
}

struct PercentageGraphSettings: View {
    @Setting(Settings.cpuGraphScale) private var cpu: CPUGraphScale
    @Setting(Settings.gpuTimeGraphScale) private var gpu: CPUGraphScale
    var body: some View {
        Section("Graph scales") {
            Picker("CPU graphs", selection: $cpu) {
                Text("Auto").tag(CPUGraphScale.auto)
                Text("Fixed at 100%").tag(CPUGraphScale.full)
            }
            Picker("GPU-time graphs", selection: $gpu) {
                Text("Auto").tag(CPUGraphScale.auto)
                Text("Fixed at 100%").tag(CPUGraphScale.full)
            }
            Text("CPU includes core and History graphs. GPU time includes apps and process details. "
                 + "Rates, clocks and memory sizes keep their own scales.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
    }
}
