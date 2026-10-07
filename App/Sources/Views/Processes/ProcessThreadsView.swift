import OTMKit
import SwiftUI

/// The inspector's Threads tab: each of the process's threads with its CPU
/// since the last reading, state and priority. Read off the main actor once
/// per tick, for the selected process only and only while the tab shows
/// (the inspector drops the view on any other tab). macOS lists threads
/// only for your own processes, so others' say so instead.
struct ProcessThreadsView: View {
    @Environment(AppModel.self) private var model
    var process: ProcessSample
    @AppStorage("threadSortKey") private var sortKey: ThreadSortKey = .cpu
    @State private var tracker = ThreadActivityTracker()
    @State private var rows: [ThreadActivity] = []
    @State private var failure: ProcessReadFailure?
    @State private var isReading = false
    @State private var isSampling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if process.isRestricted || failure == .denied {
                unreadable
            } else if rows.isEmpty {
                Text(failure == nil ? "Reading threads…" : "Its threads couldn't be read: it may have ended.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            } else {
                list
                sampleAction
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: read)
        .onChange(of: model.snapshot?.timestamp) { read() }
        .onChange(of: process.identity) {
            rows = []
            failure = nil
            read()
        }
    }

    // MARK: List

    private var list: some View {
        let sorted = ThreadActivitySort.sorted(rows, by: sortKey, ascending: sortKey == .name || sortKey == .id,
                                               cpuStep: model.cpuScale.shownStep)
        return VStack(alignment: .leading, spacing: 6) {
            summary
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                // Lazy: a busy app can have hundreds of threads.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { row in
                        ThreadRow(row: row, cpu: row.cpuPercent.map(model.cpuScale.format) ?? "—")
                    }
                }
            }
        }
    }

    private var summary: some View {
        let totals = ThreadSummary(rows)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(String(totals.count)) threads · \(String(totals.running)) running"
                + (totals.cpuPercent.map { " · \(model.cpuScale.format($0)) CPU" } ?? ""))
                .font(.callout)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Menu {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(ThreadSortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text("Sort: \(sortKey.title)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.callout)
            .help("Sort the threads: busiest first by CPU, or by CPU time, name, thread ID, state or priority")
        }
    }

    private var header: some View {
        HStack(spacing: ThreadRow.spacing) {
            Text("Thread").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: ThreadRow.cpuWidth, alignment: .trailing)
                .help("Each thread's share of the CPU since the last reading, on the same scale as the process's")
            Text("State").frame(width: ThreadRow.stateWidth, alignment: .leading)
                .help("Running: on a core now. Waiting: for a lock, a message, a timer or work. Blocked: for something "
                    + "it can't be interrupted from, usually the disk.")
            Text("Pri").frame(width: ThreadRow.priorityWidth, alignment: .trailing)
                .help("Priority: the thread's scheduling priority now, 0 to 127; higher runs first")
        }
        .font(.callout)
        .foregroundStyle(.secondaryText)
        .padding(.bottom, 3)
    }

    // MARK: Without access

    private var unreadable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Threads not readable without admin rights").font(.callout.weight(.medium))
            Text("macOS lists a process's threads only for your own processes, or to an administrator (root). "
                + "This one runs as \(process.userName).")
                .font(.explanation).foregroundStyle(.secondaryText)
            if process.threadCount > 0 {
                Text("It has \(String(process.threadCount)) threads.").font(.explanation).foregroundStyle(.secondaryText)
            }
        }
    }

    // MARK: Sample

    /// Beside the list: the call stacks behind its figures.
    private var sampleAction: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(isSampling ? "Sampling…" : "Sample Process") {
                guard let run = model.sampleProcess(process.pid) else { return }
                isSampling = true
                Task {
                    await run.value
                    isSampling = false
                }
            }
            .disabled(isSampling)
            Text("Records every thread's call stacks for 3 seconds, then opens the report.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
        .padding(.top, 4)
    }

    // MARK: Reading

    /// One reading at a time, at most once per tick; a thread list takes a
    /// call per thread, so it's read off the main actor.
    private func read() {
        guard !process.isRestricted, !isReading else { return }
        isReading = true
        let identity = process.identity
        Task {
            let (result, time) = await Task.detached(priority: .utility) {
                (ProcessDetailReader.threads(identity), ProcessInfo.processInfo.systemUptime)
            }.value
            isReading = false
            // Another process was selected meanwhile.
            guard identity == process.identity else { return }
            switch result {
            case let .success(threads):
                rows = tracker.update(threads, of: identity, at: time)
                failure = nil
            case let .failure(reason):
                tracker.reset()
                rows = []
                failure = reason
            }
        }
    }
}

/// A thread: its name (or "Unnamed") over its ID and CPU time, then its CPU,
/// state and priority in columns.
private struct ThreadRow: View, Equatable {
    var row: ThreadActivity
    var cpu: String

    static let spacing: CGFloat = 8
    static let cpuWidth: CGFloat = 50
    static let stateWidth: CGFloat = 62
    static let priorityWidth: CGFloat = 26

    var body: some View {
        let thread = row.thread
        HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.name ?? "Unnamed")
                    .foregroundStyle(thread.name == nil ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(thread.name ?? "macOS keeps a name only for threads that gave themselves one")
                // Hexadecimal, as `sample` and spindump print thread IDs.
                Text("0x\(String(thread.id, radix: 16)) · \(Format.cpuTime(thread.cpuTime))")
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .help("Thread ID, and the CPU time it has used since it started")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cpu).frame(width: Self.cpuWidth, alignment: .trailing)
            Text(thread.state.title).frame(width: Self.stateWidth, alignment: .leading)
            Text(String(thread.priority)).frame(width: Self.priorityWidth, alignment: .trailing)
                .help("Priority \(String(thread.priority)), from a base of \(String(thread.basePriority)); \(thread.policy.title.lowercased())")
        }
        .font(.tableText)
        .monospacedDigit()
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }
}
