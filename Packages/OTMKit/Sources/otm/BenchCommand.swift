import Darwin
import Foundation
import OTMKit

// `otm bench`: every saved CPU, GPU, disk and Internet result, as the app's
// Benchmarks workspace reads them, and a comparison of two. It only reads.

/// `otm bench [list|compare A B] [--json]`. Runs are numbered newest first
/// across the four tests, so `compare` takes two numbers from `list`.
func benchCommand(_ options: Options) {
    let runs = BenchmarkLibrary().load()
    let arguments = options.positional
    switch arguments.first ?? "list" {
    case "list":
        if options.json {
            printJSON(BenchmarkExport(exported: Date(), app: "otm \(version)", runs: runs))
        } else {
            print(benchList(runs))
        }
    case "compare":
        guard arguments.count == 3, let first = Int(arguments[1]), let second = Int(arguments[2]) else {
            fail("compare needs two run numbers from `otm bench list`, e.g. otm bench compare 3 1")
        }
        for number in [first, second] where !runs.indices.contains(number - 1) {
            fail("there's no run #\(number): `otm bench list` numbers \(runs.count) saved \(runs.count == 1 ? "run" : "runs")")
        }
        let one = runs[first - 1]
        let other = runs[second - 1]
        let outcome = BenchmarkComparison.compare(one, other)
        if options.json {
            printJSON(BenchmarkExport(exported: Date(), app: "otm \(version)", runs: [one, other], comparisons: [(one, other)]))
        }
        switch outcome {
        case let .refused(refusal):
            if options.json { exit(1) }
            fail("can't compare #\(first) and #\(second). \(refusal.reason)")
        case let .compared(comparison):
            if !options.json {
                let numbers = [one.id: first, other.id: second]
                print(benchComparison(comparison, runs: [one, other], numbers: numbers))
            }
        }
    default:
        fail("unknown bench command \(arguments[0]): use list or compare")
    }
}

private let benchDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

func benchList(_ runs: [BenchmarkRun]) -> String {
    guard !runs.isEmpty else {
        return "No saved results yet. Run otm cpubench, otm gpubench, otm diskspeed or otm netquality, "
            + "or a test on the app's Performance page."
    }
    var lines = [pad("#", 4, right: true) + "  " + pad("TEST", 18) + pad("WHEN", 18) + pad("BUILD", 9) + pad("ON", 25) + " FIGURES"]
    for (index, run) in runs.enumerated() {
        // The volume or interface, or the chip without the model ("Apple M5 Pro").
        let on = run.target?.name ?? run.machine.map { $0.name.components(separatedBy: " · ")[0] } ?? "—"
        lines.append(pad("\(index + 1)", 4, right: true) + "  " + pad(run.kind.title, 18) + pad(benchDate.string(from: run.date), 18)
            + pad(run.build?.title.lowercased() ?? "—", 9) + pad(on, 25) + " " + run.headlineSummary)
    }
    lines += [
        "",
        "Newest first. Compare two runs of the same test with: otm bench compare OLDER NEWER. "
            + "Disk and Internet results don't record a build; their figures don't depend on it.",
    ]
    return lines.joined(separator: "\n")
}

func benchComparison(_ comparison: BenchmarkComparison, runs: [BenchmarkRun], numbers: [String: Int]) -> String {
    guard let earlier = runs.first(where: { $0.id == comparison.baseline }),
          let later = runs.first(where: { $0.id == comparison.compared }) else { return "" }
    func label(_ run: BenchmarkRun) -> String {
        let build = run.build.map { ", \($0.title.lowercased())" } ?? ""
        return "#\(numbers[run.id] ?? 0) (\(benchDate.string(from: run.date))\(build))"
    }
    let on = [earlier.machine?.name, earlier.target?.name].compactMap { $0 }.joined(separator: " · ")
    var lines = [
        "\(earlier.kind.title): \(label(earlier)) → \(label(later))",
        (on.isEmpty ? "" : "\(on) · ") + "\(earlier.kind.versionName) v\(earlier.workloadVersion)",
        "",
        pad("FIGURE", 26) + pad("EARLIER", 15) + pad("LATER", 15) + pad("CHANGE", 9) + pad("SPREAD", 18) + "VERDICT",
    ]
    for change in comparison.changes {
        lines.append(pad(change.title, 26) + pad(change.unit.format(change.baseline), 15) + pad(change.unit.format(change.compared), 15)
            + pad(change.change.map(BenchmarkChange.formatChange) ?? "—", 9) + pad(change.spreadText, 18) + change.verdict.title.lowercased())
    }
    lines += ["", "A change counts only when the two runs' ranges of repeats, slowest to fastest, don't overlap; "
        + "± is half a run's range."]
    lines += comparison.caveats
    return lines.joined(separator: "\n")
}
