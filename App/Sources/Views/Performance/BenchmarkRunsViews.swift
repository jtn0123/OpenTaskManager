import OTMKit
import SwiftUI

/// Measurements that share a name ("Integer" on one worker and on all),
/// side by side in a table under one heading, in one unit.
struct BenchmarkFigureGroup: Identifiable {
    let name: String
    let ids: [String]
    /// "GB/s", and what to divide by for it.
    let unit: String
    let divisor: Double

    var id: String { ids.first ?? name }

    /// The ids in order, grouped by name, each group scaled to its largest figure in `runs`.
    static func groups(_ ids: [String], in runs: [BenchmarkRun]) -> [BenchmarkFigureGroup] {
        var groups: [BenchmarkFigureGroup] = []
        var pending: [String] = []
        func close() {
            guard let first = pending.first, let sample = runs.lazy.compactMap({ $0.measurement(first) }).first else { return }
            let largest = runs.flatMap { run in pending.compactMap { run.measurement($0)?.value } }.max() ?? 0
            let scale = sample.unit.scale(largest)
            groups.append(BenchmarkFigureGroup(name: sample.name, ids: pending, unit: scale.unit, divisor: scale.divisor))
            pending = []
        }
        for id in ids {
            let name = runs.lazy.compactMap { $0.measurement(id)?.name }.first
            if let first = pending.first, runs.lazy.compactMap({ $0.measurement(first)?.name }).first != name { close() }
            pending.append(id)
        }
        close()
        return groups
    }
}

// MARK: - Saved runs and comparison

/// A test's saved runs, newest first, each with a box to pick it for
/// comparison, and the comparison of the two picked. Debug builds' runs are
/// marked; with one run picked, those it can't be compared with are dimmed,
/// the reason in their tooltip. It changes only with the runs or the picks.
struct SavedRuns: View, Equatable {
    let kind: BenchmarkKind
    let runs: [BenchmarkRun]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.runs == rhs.runs
    }

    var body: some View {
        let workspace = BenchmarkWorkspace.shared
        let picked = workspace.picked(kind, among: runs)
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Saved runs").font(.callout.weight(.semibold))
                Text(hint(picked))
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RunsTable(kind: kind, runs: runs, picked: picked)
            if let caveat = runs.lazy.flatMap(\.measurements).compactMap(\.caveat).first {
                FigureCaveatFootnote(caveat: caveat)
            }
            if picked.count == 2 {
                ComparisonPanel(kind: kind, earlier: picked[0], later: picked[1])
                    .modifier(BenchmarkScrollAnchor(id: BenchmarkAnchor.comparison(kind)))
            }
        }
    }

    private func hint(_ picked: [BenchmarkRun]) -> String {
        if runs.count < 2 { return "Run the test again to compare two runs." }
        switch picked.count {
        case 0: return "Tick two to compare them."
        case 1: return "Tick one more to compare it with \(BenchmarkLook.when(picked[0].date))."
        default: return ""
        }
    }
}

private struct RunsTable: View {
    let kind: BenchmarkKind
    let runs: [BenchmarkRun]
    let picked: [BenchmarkRun]

    var body: some View {
        let ids = Self.ids(runs)
        let groups = BenchmarkFigureGroup.groups(ids, in: runs)
        let variants = groups.contains { $0.ids.count > 1 }
        let showsBuild = runs.contains { $0.build != nil }
        let showsTarget = !kind.measuresThisMac || kind == .disk
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
            // A heading wraps over its unit, to three lines ("Random / 4K read / IOPS"), rather than truncate where the card is narrow.
            GridRow(alignment: .bottom) {
                Text("").gridColumnAlignment(.leading)
                Text(variants ? "" : "When").gridColumnAlignment(.leading)
                if showsBuild { Text(variants ? "" : "Build").gridColumnAlignment(.leading) }
                if showsTarget { Text(variants ? "" : "On").gridColumnAlignment(.leading) }
                ForEach(groups) { group in
                    Text("\(group.name) \(group.unit)")
                        .lineLimit(3)
                        .multilineTextAlignment(group.ids.count > 1 ? .center : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(group.ids.count)
                        .gridCellAnchor(group.ids.count > 1 ? .center : .trailing)
                }
            }
            if variants {
                GridRow {
                    Text("")
                    Text("When")
                    if showsBuild { Text("Build") }
                    if showsTarget { Text("On") }
                    ForEach(groups) { group in
                        ForEach(group.ids, id: \.self) { id in
                            Text(Self.shortVariant(runs.lazy.compactMap { $0.measurement(id)?.variant }.first))
                        }
                    }
                }
                .help("One worker, then one per logical CPU")
            }
            ForEach(runs) { run in
                RunRow(run: run, groups: groups, showsBuild: showsBuild, showsTarget: showsTarget,
                       picked: picked.contains { $0.id == run.id }, refusal: refusal(run))
            }
        }
        .font(.tableText)
        .foregroundStyle(.secondaryText)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// Why `run` can't be compared with the one run picked.
    private func refusal(_ run: BenchmarkRun) -> BenchmarkRefusal? {
        guard picked.count == 1, let one = picked.first, one.id != run.id else { return nil }
        guard case let .refused(refusal) = BenchmarkComparison.compare(one, run) else { return nil }
        return refusal
    }

    /// Every measurement's id, in the order the runs list them, newest first.
    private static func ids(_ runs: [BenchmarkRun]) -> [String] {
        var ids: [String] = []
        for run in runs {
            for measurement in run.measurements where !ids.contains(measurement.id) {
                ids.append(measurement.id)
            }
        }
        return ids
    }

    /// "8" for "8 workers", as the column's heading under its measure.
    private static func shortVariant(_ variant: String?) -> String {
        guard let variant else { return "" }
        let first = variant.split(separator: " ").first.map(String.init) ?? variant
        return Int(first) != nil ? first : variant
    }
}

private struct RunRow: View {
    let run: BenchmarkRun
    let groups: [BenchmarkFigureGroup]
    let showsBuild: Bool
    let showsTarget: Bool
    let picked: Bool
    let refusal: BenchmarkRefusal?

    var body: some View {
        let debug = run.build?.optimized == false
        let dimmed = refusal != nil || debug
        GridRow {
            Toggle("Compare", isOn: Binding(get: { picked }, set: { _ in BenchmarkWorkspace.shared.togglePick(run) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Compare the run of \(BenchmarkLook.when(run.date))")
            Text(BenchmarkLook.when(run.date)).fixedSize()
            if showsBuild {
                Text(run.build?.title ?? "—")
                    .fontWeight(debug ? .semibold : .regular)
                    .foregroundStyle(debug ? AnyShapeStyle(BenchmarkLook.debug) : AnyShapeStyle(.secondaryText))
            }
            if showsTarget {
                // Room for a usual volume name ("Macintosh HD") before the wrapping headings take it.
                Text(run.target?.name ?? "—").truncationMode(.middle).frame(minWidth: 90, maxWidth: 140, alignment: .leading)
            }
            ForEach(groups) { group in
                ForEach(group.ids, id: \.self) { id in
                    let measurement = run.measurement(id)
                    let number = measurement.map { $0.unit.number($0.value, divisor: group.divisor) } ?? "—"
                    let spread = measurement?.plusMinus.map { "\($0) over \(measurement?.repeats ?? 0) repeats" } ?? ""
                    if let caveat = measurement?.caveat {
                        // Marked at the figure, which drops to secondary text.
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            FigureCaveatMark(caveat: caveat)
                            Text(number).foregroundStyle(.secondaryText).fontWeight(.regular)
                        }
                        .help("\(caveat.title): \(caveat.explanation)" + (spread.isEmpty ? "" : " (\(spread))"))
                    } else {
                        Text(number).help(spread)
                    }
                }
            }
        }
        .fontWeight(picked ? .semibold : nil)
        .foregroundStyle(dimmed ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
        .opacity(refusal != nil ? 0.7 : 1)
        .help(refusal.map { "Can't be compared with the run picked: \($0.reason)" } ?? Self.details(run))
    }

    private static func details(_ run: BenchmarkRun) -> String {
        var parts = [run.build.map { "\($0.title) build · \($0.app)" }, run.osVersion, run.target?.detail].compactMap { $0 }
        parts += run.conditions
        return parts.joined(separator: " · ")
    }
}

/// The two picked runs compared figure by figure, or why they can't be.
private struct ComparisonPanel: View {
    let kind: BenchmarkKind
    let earlier: BenchmarkRun
    let later: BenchmarkRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(BenchmarkLook.when(earlier.date)) → \(BenchmarkLook.when(later.date))")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Button("Clear") { BenchmarkWorkspace.shared.clearPicks(kind) }
                    .help("Untick both runs")
            }
            switch BenchmarkComparison.compare(earlier, later) {
            case let .refused(refusal):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "nosign").font(.title3).foregroundStyle(BenchmarkLook.debug)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not compared").font(.body.weight(.semibold))
                        Text(refusal.reason)
                            .font(.body)
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BenchmarkLook.debug.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BenchmarkLook.debug.opacity(0.35)))
            case let .compared(comparison):
                ChangeTable(changes: comparison.changes)
                ForEach(comparison.caveats, id: \.self) { caveat in
                    Label(caveat, systemImage: "info.circle")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("A change counts only when the two runs' ranges of repeats, slowest to fastest, don't overlap; "
                    + "± is half a run's range.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }
}

private struct ChangeTable: View {
    let changes: [BenchmarkChange]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Figure").gridColumnAlignment(.leading)
                Text("Earlier")
                Text("Later")
                Text("Change")
                Text("Spread")
                Text("Verdict").gridColumnAlignment(.leading)
            }
            .foregroundStyle(.secondaryText)
            ForEach(changes) { change in
                // Figures keep their width; in a narrow window the name and
                // the verdict wrap instead.
                // A figure in doubt in either run is marked at its figures,
                // which drop to secondary text, and its verdict isn't coloured.
                GridRow {
                    Text(change.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    figure(change.unit.format(change.baseline), caveat: change.baselineCaveat)
                    figure(change.unit.format(change.compared), caveat: change.comparedCaveat)
                    Text(change.change.map(BenchmarkChange.formatChange) ?? "—")
                        .fontWeight(change.caveat == nil ? .semibold : .regular)
                        .foregroundStyle(change.caveat == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
                        .fixedSize()
                    Text(change.spreadText).foregroundStyle(.secondaryText).fixedSize()
                    Label(change.verdict.title, systemImage: Self.symbol(change.verdict))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(change.caveat == nil ? Self.color(change.verdict) : AnyShapeStyle(.secondaryText))
                        .help(change.verdict.explanation + (change.caveatNote.map { " \($0)" } ?? ""))
                }
            }
        }
        .font(.tableText)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder
    private func figure(_ text: String, caveat: BenchmarkFigureCaveat?) -> some View {
        if let caveat {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                FigureCaveatMark(caveat: caveat)
                Text(text).foregroundStyle(.secondaryText)
            }
            .fixedSize()
            .help("\(caveat.title): \(caveat.explanation)")
        } else {
            Text(text).fixedSize()
        }
    }

    private static func symbol(_ verdict: BenchmarkChange.Verdict) -> String {
        switch verdict {
        case .better: "checkmark.circle.fill"
        case .worse: "exclamationmark.circle.fill"
        case .withinSpread: "equal.circle"
        case .measuredOnce: "questionmark.circle"
        case .unchanged: "equal.circle"
        }
    }

    private static func color(_ verdict: BenchmarkChange.Verdict) -> AnyShapeStyle {
        switch verdict {
        case .better: AnyShapeStyle(BenchmarkLook.better)
        case .worse: AnyShapeStyle(BenchmarkLook.worse)
        case .withinSpread, .measuredOnce, .unchanged: AnyShapeStyle(.secondaryText)
        }
    }
}
