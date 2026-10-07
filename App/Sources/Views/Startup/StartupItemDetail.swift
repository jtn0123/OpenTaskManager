import OTMKit
import SwiftUI

/// The inspector for one startup item: what it runs, what starts it, and
/// where its property list lives.
struct StartupItemDetail: View {
    var item: LaunchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    if let note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
                    program
                    launches
                    labelled("Property list", item.plistPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Reveal in Finder") { StartupActions.reveal(item) }
                Button("Show plist") { StartupActions.openPlist(item) }
                Spacer()
            }
        }
        .padding(12)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forBundle: item.appBundlePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(2)
                Text(item.label)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                LaunchStateLabel(state: item.state)
            }
            .font(.callout)
            if let disabledBy {
                FactRow(label: "Disabled by", value: disabledBy)
            }
            FactRow(label: "Kind", value: item.scope.title)
            FactRow(label: "Publisher", value: item.publisher.title)
            FactRow(label: "Last exit", value: lastExit)
            if let modified = item.modified {
                FactRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder private var program: some View {
        if let path = item.program {
            labelled("Program", path)
        } else if !item.isUnreadable {
            labelled("Program", "None: the property list names no program")
        }
        let arguments = item.arguments.first == item.program ? Array(item.arguments.dropFirst()) : item.arguments
        if !arguments.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Arguments").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                    Text(argument).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var launches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launches").font(.subheadline).foregroundStyle(.secondary)
            if item.isUnreadable {
                Text("Unknown: the property list can't be read").font(.callout)
            } else {
                ForEach(item.triggers.details(for: item.scope), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondary)
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Text

    private var lastExit: String {
        if let exit = item.job?.lastExit { return exit.description }
        return item.job == nil ? "—" : "Hasn't exited"
    }

    private var disabledBy: String? {
        switch (item.disabledOverride, item.disabledInPlist) {
        case (true?, _): "launchctl disable"
        case (nil, true): "Its Disabled key"
        default: nil
        }
    }

    /// Why an item won't load, or that an override beats its plist.
    private var note: String? {
        if item.isMissingLabel { return "This property list has no Label, so launchd ignores it." }
        if item.isUnreadable { return "This property list can't be read, so its settings are unknown." }
        if item.disabledOverride == false, item.disabledInPlist {
            return "Enabled with launchctl, which overrides the Disabled key in its property list."
        }
        return nil
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
