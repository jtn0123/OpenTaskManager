import OTMKit
import SwiftUI

struct SoftwareUpdateSettings: View {
    @Setting(Settings.automaticUpdateChecks) private var automatic: Bool
    private var store: UpdateCheckStore { .shared }

    var body: some View {
        Section("Software updates") {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { _, enabled in
                    if enabled { Task { await store.check(automatic: true) } }
                }
            Text("Checks public GitHub Releases when you open or return to the app, at most once a day. "
                 + "GitHub receives a standard web request; no system readings are sent.")
                .font(.explanation).foregroundStyle(.secondaryText)
            SoftwareUpdateContent()
        }
    }
}

struct SoftwareUpdateContent: View {
    private var store: UpdateCheckStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.preview { Text("Example update information").font(.explanation).foregroundStyle(.orange) }
            Text("Installed version: \(store.currentVersion)").font(.tableText)
            HStack {
                Button(store.state == .checking ? "Checking…" : "Check Now") { Task { await store.check() } }
                    .disabled(store.state == .checking)
                if store.state == .checking { ProgressView().controlSize(.small) }
            }
            Text(store.message).font(.explanation).foregroundStyle(.secondaryText)
                .accessibilityIdentifier("updateCheckStatus")
            if case .checked(.available(let update)) = store.state {
                Link("View Release on GitHub…", destination: update.page)
                    .font(.tableText)
            }
            if let checked = store.lastChecked {
                Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.metadata).foregroundStyle(.secondaryText)
            }
            Text("Downloads and installation are manual. This app opens the release page in your browser.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SoftwareUpdateWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Software Updates", systemImage: "arrow.down.circle").font(.title2.bold())
            SoftwareUpdateContent()
        }
        .padding(24)
        .frame(width: 420)
        .task { await UpdateCheckStore.shared.check() }
    }
}
