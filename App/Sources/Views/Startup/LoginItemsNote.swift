import SwiftUI

/// The app bundles reveal shipped registrations, but not macOS approval switches.
struct LoginItemsNote: View {
    static let settings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Select an item to see its state and available controls. macOS keeps background approvals and Open at Login apps private; "
                + "change those in Login Items Settings.", systemImage: "info.circle")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .help("An item inside an app may not be registered or allowed: launchd's list confirms the ones loaded, "
                    + "but macOS keeps its list of allowed items and Open at Login apps private. Login Items Settings "
                    + "shows both. Apple's own jobs without a file, services macOS starts on demand, are left out.")
            Spacer(minLength: 0)
            Button("Open Login Items Settings") {
                if let url = Self.settings { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}
