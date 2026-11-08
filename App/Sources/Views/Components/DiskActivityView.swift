import OTMKit
import SwiftUI

struct DiskLightPair: View {
    var reading: Bool
    var writing: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text("R")
            Image(systemName: reading ? "circle.fill" : "circle").foregroundStyle(reading ? Color.green : .secondary)
            Text("W").padding(.leading, 3)
            Image(systemName: writing ? "circle.fill" : "circle").foregroundStyle(writing ? Color.orange : .secondary)
        }
        .font(.system(size: 10, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Read \(reading ? "active" : "idle"), write \(writing ? "active" : "idle")")
    }
}

struct DiskActivityMenuRows: View {
    var store: DiskActivityStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.paused ? "Disk activity · paused" : "Disk activity · last sample").font(.metadata).foregroundStyle(.secondaryText)
            ForEach(store.lights) { light in
                HStack {
                    Text(light.name).font(.tableText).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    DiskLightPair(reading: light.reading, writing: light.writing)
                }
            }
            if store.lights.isEmpty { Text("No selected physical disks connected.").font(.explanation).foregroundStyle(.secondaryText) }
        }
    }
}

struct DiskActivitySettings: View {
    @Environment(AppModel.self) private var model
    @Setting(Settings.diskActivityLights) private var shown: Bool
    @Setting(Settings.diskLightSelection) private var selection: DiskLightSelection

    var body: some View {
        Section("Disk activity lights") {
            Toggle("Read/write lights in the menu bar", isOn: $shown)
            if shown {
                Toggle("All physical disks", isOn: Binding(get: { selection.isAll }, set: { selection = $0 ? .all : .init(rawValue: "") }))
                if !selection.isAll {
                    ForEach((model.snapshot?.disks ?? []).filter { !$0.isDiskImage }) { disk in
                        Toggle("\(disk.name ?? disk.model ?? disk.bsdName) (\(disk.bsdName))", isOn: Binding {
                            selection.contains(disk.bsdName)
                        } set: { _ in selection.toggle(disk.bsdName) })
                    }
                }
                Text("R lights up for reads; W for writes. Each light describes the last metrics sample. "
                     + "The app keeps running when its main window closes. Show in menu bar must also be enabled.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
        }
    }
}
