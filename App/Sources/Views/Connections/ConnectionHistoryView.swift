import AppKit
import OTMKit
import SwiftUI

/// Static query results. Walks may update the count's caption, never reload this table.
struct ConnectionHistoryView: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var range: ConnectionHistoryRange = .today
    @State private var rows: [ConnectionLifetime] = []
    @State private var coverage: ConnectionHistoryCoverage?
    @State private var selection: String?
    @State private var coversList = false
    @State private var isNarrow = false
    @State private var error: String?
    @State private var loaded = false

    private var selected: ConnectionLifetime? { rows.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Interval", selection: $range) {
                    ForEach(ConnectionHistoryRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 0)
                Text(rows.count == 1 ? "1 \(search.isEmpty ? "stored" : "matching") lifetime"
                     : "\(rows.count.formatted()) \(search.isEmpty ? "stored" : "matching") lifetimes")
                    .font(.metadata).foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let coverage {
                Text(coverage.summary).font(.explanation).foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .help(coverage.watchedWords)
            }
            InspectorSplit(listMinimum: 480, wantsInspector: selected != nil, coversList: $coversList,
                           isNarrow: $isNarrow, widthKey: Settings.connectionInspectorWidth, backTitle: "Connection History") {
                if let error {
                    ContentUnavailableView("History unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if !loaded {
                    ProgressView("Reading socket history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No stored lifetimes" : "No matching lifetimes", systemImage: "clock")
                    } description: {
                        Text(coverage?.watchedWords ?? "Not watched in this range").lineLimit(6)
                    }
                    .help(coverage?.watchedWords ?? "Not watched in this range")
                } else {
                    // Only as tall as its rows, and under the pickers beside
                    // the details too, not in the middle of the pane.
                    VStack(spacing: 0) {
                        historyTable.layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                }
            } detail: {
                if let selected {
                    ConnectionDetail(row: detailRow(selected), showProcess: {}, close: coversList ? nil : { selection = nil })
                }
            }
        }
        // A short list sits under the pickers, not in the middle of the page.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: Query(search: search, range: range)) { await load() }
        .onChange(of: selection) { if isNarrow { coversList = selection != nil } }
    }

    private struct Query: Equatable {
        let search: String
        let range: ConnectionHistoryRange
    }

    private var historyTable: some View {
        Table(rows, selection: $selection) {
            TableColumn("Process") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.process.name).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "PID \(row.socket.connection.pid)").font(.metadata).foregroundStyle(.secondaryText)
                }
                .help(row.process.path ?? row.process.name)
            }
            TableColumn("Local → remote") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.socket.connection.local.formatted)
                    Text(row.socket.connection.remote?.formatted ?? "No remote endpoint").foregroundStyle(.secondaryText)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.socket.connection.local.formatted + " → " + (row.socket.connection.remote?.formatted ?? "—"))
            }
            TableColumn("Protocol") { Text($0.socket.connection.transport.rawValue) }.width(60)
            TableColumn("First / last seen") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stamp(row.socket.firstSeen))
                    Text(stamp(row.socket.lastSeen)).foregroundStyle(.secondaryText)
                }
            }
            TableColumn("How it ended") { row in
                Text(row.endedWords(time: ConnectionClock.time)).lineLimit(3)
            }
        }
        .font(.tableText)
        .frame(minWidth: 0, maxWidth: .infinity)
        .fitsTableToRows(rows.count)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Show in History") { HistoryRecordingStore.shared.showConnectionMoment(row.socket.lastSeen) }
            }
        } primaryAction: { ids in
            selection = ids.first
            if isNarrow { coversList = true }
        }
    }

    private func detailRow(_ row: ConnectionLifetime) -> ConnectionRow {
        ConnectionRow(socket: row.socket, look: .init(name: row.process.name, icon: IconCache.generic),
                      at: coverage?.to ?? .now, processRunning: false, lifetime: row)
    }

    /// Today's times stand alone; earlier ones name their day.
    private func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(.dateTime.hour().minute().second())
            : date.formatted(.dateTime.month().day().hour().minute().second())
    }

    private func load() async {
        let query = Query(search: search, range: range)
        let end = Date.now
        let start = range.start(before: end)
        do {
            guard let recorder = model.recorder else {
                error = "The flight recorder could not open its database."
                guard !Task.isCancelled else { return }
                loaded = true
                return
            }
            guard try await recorder.keepsConnectionHistory() else {
                error = "Socket history has not been recorded by this version yet."
                guard !Task.isCancelled else { return }
                loaded = true
                return
            }
            let result = try await recorder.connectionHistoryResult(matching: search, from: start, to: end)
            guard !Task.isCancelled, query == Query(search: search, range: range) else { return }
            rows = result.lifetimes
            coverage = result.coverage
            error = nil
            loaded = true
            if selection == nil, let requested = LaunchArgument.string("openConnection") {
                selection = result.lifetimes.first { $0.matches(requested) }?.id
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }
}
