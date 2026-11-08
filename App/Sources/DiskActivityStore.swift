import Foundation
import Observation
import OTMKit

/// No timer or sampling demand. The menu icon observes only Boolean lights,
/// so changing rates with the same read/write state do not redraw it.
@Observable
@MainActor
final class DiskActivityStore {
    private(set) var enabled = false
    private(set) var paused = false
    private(set) var lights: [DiskActivityLight] = []
    @ObservationIgnored private var selection = DiskLightSelection.all
    @ObservationIgnored private var disks: [DiskSample] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    private func sync() {
        let nextEnabled = Settings.diskActivityLights.get(in: defaults)
        let nextSelection = Settings.diskLightSelection.get(in: defaults)
        guard enabled != nextEnabled || selection != nextSelection else { return }
        enabled = nextEnabled
        selection = nextSelection
        if !enabled { disks = [] }
        publish()
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        publish()
    }

    func update(_ disks: @autoclosure () -> [DiskSample], visible: Bool) {
        guard enabled else { return }
        self.disks = disks()
        if visible { publish() }
    }

    private func publish() {
        let next = enabled ? DiskActivityLight.readings(disks, selection: selection, paused: paused) : []
        if lights != next { lights = next }
    }
}
