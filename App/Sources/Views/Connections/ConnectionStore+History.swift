import Foundation
import OTMKit

extension ConnectionStore {
    /// Only the deadline check uses sampler wakeups; a walk and its metadata are made once a minute at most.
    func sampleBackground(model: AppModel, processes: [ProcessSample]) {
        guard visibleVisits == 0 || !model.samplingDemand.hasVisibleWindow else { return }
        let enabled = Settings.backgroundConnections.get() && model.recorder != nil && !model.showsSensorFixture && !model.isPaused
        guard enabled else {
            stopUnlessBackground(force: true)
            return
        }
        guard walkTask == nil, Date.now >= nextBackgroundWalk else { return }
        nextBackgroundWalk = Date.now.addingTimeInterval(60)
        historyRecorder = model.recorder
        let metadata = connectionProcesses(processes, model: model)
        let pendingStop = stoppingTask
        let recorder = model.recorder
        let task = Task {
            if let pendingStop { await pendingStop.value }
            return await historyWorker.read(recorder: recorder, spacing: 60, processes: metadata)
        }
        walkTask = task
        Task {
            let reading = await task.value
            watch = reading.watch
            walkTask = nil
            // No view state is published while the page is away.
        }
    }

    func connectionProcesses(_ processes: [ProcessSample], model: AppModel) -> [ProcessIdentity: ConnectionProcess] {
        var metadata: [ProcessIdentity: ConnectionProcess] = [:]
        for process in processes {
            metadata[process.identity] = ConnectionProcess(name: model.displayName(for: process),
                                                           path: process.executablePath, user: process.userName)
        }
        return metadata
    }

    func stopUnlessBackground(force: Bool = false) {
        guard force || !(Settings.backgroundConnections.get() && historyRecorder != nil) else { return }
        guard stoppingTask == nil, historyRecorder != nil else { return }
        let recorder = historyRecorder
        historyRecorder = nil
        let running = walkTask
        stoppingTask = Task {
            if let running { _ = await running.value }
            await historyWorker.stop(recorder: recorder)
            stoppingTask = nil
        }
    }

    func finishHistory() async {
        if let walkTask { _ = await walkTask.value }
        if let stoppingTask { await stoppingTask.value }
        await historyWorker.stop(recorder: historyRecorder)
    }
}
