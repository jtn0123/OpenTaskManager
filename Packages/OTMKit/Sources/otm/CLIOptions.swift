import OTMKit

struct Options {
    var command = "ps"
    var positional: [String] = []
    var count = 20
    var sort = "cpu"
    var json = false
    var all = false
    var interval = 1.0
    var signal = "term"
    var depth = 1
    var sizes = false
    var source: LaunchItemSource?
    var schedule = false
    var changes = false
    var listeners = false
    var reconcile = false
    var extremes: Double?
    var range: String?
    var since: String?
    var sustained = false
    var benchmarkRepeats = BenchmarkSessionProtocol.repeats
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    if let first = arguments.first, !first.hasPrefix("-") {
        options.command = first
        _ = iterator.next()
    }
    while let argument = iterator.next() {
        switch argument {
        case "-n", "--count": options.count = iterator.next().flatMap(Int.init) ?? options.count
        case "-s", "--sort": options.sort = iterator.next() ?? options.sort
        case "-i", "--interval": options.interval = iterator.next().flatMap(Double.init) ?? options.interval
        case "--source":
            guard let name = iterator.next(), let source = LaunchItemSource(name: name) else {
                fail("--source needs one of: " + LaunchItemSource.allCases.map(\.rawValue).joined(separator: ", "))
            }
            options.source = source
        case "--signal": options.signal = iterator.next() ?? options.signal
        case "-d", "--depth": options.depth = iterator.next().flatMap(Int.init) ?? options.depth
        case "--json": options.json = true
        case "-a", "--all": options.all = true
        case "--sizes": options.sizes = true
        case "--schedule": options.schedule = true
        case "--changes": options.changes = true
        case "--listeners": options.listeners = true
        case "--since": options.since = iterator.next()
        case "--range": options.range = iterator.next()
        case "--reconcile": options.reconcile = true
        case "--sustained": options.sustained = true
        case "--repeats":
            guard let count = iterator.next().flatMap(Int.init), BenchmarkSessionProtocol.repeatRange.contains(count) else {
                fail("--repeats needs a number from 1 to 10")
            }
            options.benchmarkRepeats = count
        case "--extremes":
            guard let seconds = iterator.next().flatMap(Double.init), seconds >= 0 else { fail("--extremes needs a number of seconds") }
            options.extremes = seconds
        case "-h", "--help": options.command = "help"
        case "-v", "--version": options.command = "version"
        default: options.positional.append(argument)
        }
    }
    return options
}
