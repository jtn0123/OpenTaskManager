import AppKit
import OTMKit

extension AppModel {
    /// Quits apps politely (like ⌘Q) and sends SIGTERM to everything else.
    func endTask(_ pids: [Int32]) {
        var signalled: [Int32] = []
        for pid in pids {
            if let app = regularApps[pid] {
                guard let identity = processIdentityByPID[pid], ProcessDetailReader.identity(of: pid) == identity else { continue }
                if app.terminate() { recordEnd(identity, signal: nil) }
            } else {
                signalled.append(pid)
            }
        }
        // `send` checks each one's identity, and asks for a password once for all.
        send(.terminate, to: signalled)
    }

    func forceQuit(_ pids: [Int32]) {
        send(.kill, to: pids)
    }

    /// Ends each process and everything it started, children first.
    func endProcessTree(_ pids: [Int32], force: Bool) {
        guard let processes = snapshot?.processes else { return }
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var ordered: [Int32] = []
        func visit(_ pid: Int32) {
            for child in children[pid] ?? [] where child.pid != pid { visit(child.pid) }
            if !ordered.contains(pid) { ordered.append(pid) }
        }
        pids.forEach(visit)
        send(force ? .kill : .terminate, to: ordered)
    }

    func send(_ signal: ProcessSignal, to pids: [Int32]) {
        var denied: [ProcessIdentity] = []
        for pid in pids {
            guard let identity = processIdentityByPID[pid], ProcessDetailReader.identity(of: pid) == identity else { continue }
            do {
                try ProcessControl.send(signal, to: pid)
                recordEnd(identity, signal: signal.rawValue)
            } catch .permissionDenied {
                denied.append(identity)
            } catch {
                reportError(error)
            }
        }
        // One password prompt for all of them. Only a command that succeeded
        // records the ends: a failed one can't say which targets got the signal.
        let targets = denied.filter { ProcessDetailReader.identity(of: $0.pid) == $0 }
        if !targets.isEmpty, runAsAdministrator(ProcessControl.shellCommand(for: signal, pids: targets.map(\.pid))) {
            for identity in targets { recordEnd(identity, signal: signal.rawValue) }
        }
        refreshSoon()
    }

    private func recordEnd(_ identity: ProcessIdentity, signal: Int32?) {
        guard signal.map({ [SIGTERM, SIGKILL, SIGINT, SIGHUP, SIGQUIT].contains($0) }) ?? true, let recorder else { return }
        let process = snapshot?.processes.first { $0.identity == identity }
        let action = ProcessEndAction(identity: identity, path: process?.executablePath, signal: signal)
        let event = HistoryEvent.endedByApp(time: Date(), name: process?.name ?? "PID \(identity.pid)", action: action)
        Task {
            do { try await recorder.append([event]) } catch { reportError(error) }
        }
    }
}
