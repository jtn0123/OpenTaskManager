import Darwin
import Foundation
import OTMKit

/// A bounded preflight and fixed protocol, with progress on stderr so stdout remains valid JSON.
func benchGuidedCommand(_ options: Options) async {
    let arguments = options.positional
    guard arguments.count <= 2, let kinds = BenchmarkSessionProtocol.kinds(arguments.dropFirst().first ?? "all") else {
        fail("use otm bench guided [cpu|gpu|all] [--json]")
    }
    let cancellation = interruptCancels()
    let gpuCancellation = GPUBenchmarkCancellation()
    defer { cancellation.interrupt.cancel() }
    let preflight = await guidedPreflight(cancellation: cancellation.token)
    guard !cancellation.token.isCancelled else { fail("Guided session cancelled.") }
    let id = UUID().uuidString
    var runs: [BenchmarkRun] = []
    for pass in BenchmarkSessionProtocol.passes(repeatCount: options.benchmarkRepeats) {
        for kind in kinds {
            guard !cancellation.token.isCancelled else { fail("Guided session cancelled; completed repeats remain saved.") }
            let label = pass == 0 ? "Warm-up (discarded)" : "Repeat \(pass) of \(options.benchmarkRepeats)"
            guidedNotice("\(label): \(kind.title)")
            let session = pass == 0 ? nil : BenchmarkSession(id: id, preflight: preflight, repeatIndex: pass, repeatCount: options.benchmarkRepeats)
            do {
                if let run = try await guidedMeasure(kind, session: session, cpuCancellation: cancellation.token,
                                                     gpuCancellation: gpuCancellation) { runs.append(run) }
            } catch {
                fail("Guided session stopped: \(error). Completed repeats remain saved.")
            }
        }
    }
    let grouped = BenchmarkRun.groupedSessions(runs)
    if options.json {
        printJSON(BenchmarkExport(exported: Date(), app: "otm \(version)", runs: runs))
    } else {
        print(preflight.rows.map(\.text).joined(separator: "\n") + "\n" + preflight.verdict + "\n\n" + benchList(grouped))
    }
}

private func guidedPreflight(cancellation: CPUBenchmarkCancellation) async -> BenchmarkPreflight {
    let reader = BenchmarkPreflightReader()
    var settling = BenchmarkSettling(started: Date())
    var deadline = BenchmarkSettling.defaultWindow
    _ = await reader.reading()
    while !cancellation.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { fail("Guided preflight cancelled.") }
        settling.append(await reader.reading())
        let snapshot = settling.snapshot(now: Date())
        if snapshot.settled { return snapshot }
        if snapshot.elapsed < deadline { continue }
        guidedNotice(snapshot.rows.map(\.text).joined(separator: "\n") + "\n" + snapshot.verdict)
        guard isatty(STDIN_FILENO) == 1 else {
            fail("The Mac did not settle. No tests ran. Retry interactively to Wait, Proceed anyway, or Cancel.")
        }
        guidedNotice(deadline < BenchmarkSettling.maximumWait
            ? "Wait [w], Proceed anyway [p], or Cancel [c]:" : "Proceed anyway [p], or Cancel [c]:")
        // Readiness callbacks keep terminal input off the main actor.
        let answer = await guidedAnswer(cancellation: cancellation)
        guard !cancellation.isCancelled else { fail("Guided preflight cancelled.") }
        switch answer {
        case "p", "proceed":
            settling.append(await reader.reading())
            return settling.snapshot(now: Date())
        case "w" where deadline < BenchmarkSettling.maximumWait, "wait" where deadline < BenchmarkSettling.maximumWait:
            deadline = min(deadline + 30, BenchmarkSettling.maximumWait)
        default: fail("Guided preflight cancelled. No tests ran.")
        }
    }
    fail("Guided preflight cancelled. No tests ran.")
}

private func guidedMeasure(_ kind: BenchmarkKind, session: BenchmarkSession?, cpuCancellation: CPUBenchmarkCancellation,
                           gpuCancellation: GPUBenchmarkCancellation) async throws -> BenchmarkRun? {
    let app = "otm \(version)"
    let context = await BenchmarkContextReader.capture(appVersion: app)
    guard !cpuCancellation.isCancelled else { throw CPUBenchmarkError.cancelled }
    switch kind {
    case .cpu:
        return try await Task.detached {
            var result = try CPUBenchmark.run(appVersion: app, cancellation: cpuCancellation)
            guard !cpuCancellation.isCancelled else { throw CPUBenchmarkError.cancelled }
            result.context = context.ended()
            result.session = session
            guard session != nil else { return nil }
            try SpeedTestHistory.cpuBenchmark.append(result)
            return BenchmarkRun(result)
        }.value
    case .gpu:
        // The interrupt token is shared with the preflight and CPU; bridge it while Metal is running.
        let watcher = Task {
            while !Task.isCancelled {
                if cpuCancellation.isCancelled { gpuCancellation.cancel(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { watcher.cancel() }
        return try await Task.detached {
            var result = try GPUBenchmark.run(appVersion: app, cancellation: gpuCancellation)
            guard !cpuCancellation.isCancelled else { throw GPUBenchmarkError.cancelled }
            result.context = context.ended()
            result.session = session
            guard session != nil else { return nil }
            try SpeedTestHistory.gpuBenchmark.append(result)
            return BenchmarkRun(result)
        }.value
    case .disk, .network, .sustained:
        return nil
    }
}

private func guidedNotice(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// A partial line never holds cancellation hostage while the terminal waits for Return.
private actor GuidedConsoleInput {
    private var buffer = Data()
    private var answer: String?

    func receive(_ data: Data) {
        if data.isEmpty { answer = "c"; return }
        buffer.append(data)
        if let newline = buffer.firstIndex(of: 10) {
            answer = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    func value() -> String? { answer }
}

private func guidedAnswer(cancellation: CPUBenchmarkCancellation) async -> String? {
    let input = GuidedConsoleInput()
    let handle = FileHandle.standardInput
    handle.readabilityHandler = { file in
        let data = file.availableData
        Task { await input.receive(data) }
    }
    defer { handle.readabilityHandler = nil }
    while !cancellation.isCancelled {
        if let answer = await input.value() { return answer }
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
    }
    return nil
}
