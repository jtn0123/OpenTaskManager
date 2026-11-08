import AppKit
import Foundation
@testable import OTMKit
import Testing

@MainActor
struct DockIconControllerTests {
    @Test func modesRestoreTheIconAndUnrelatedSettingsDoNothing() throws {
        let name = "DockIconControllerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var rendered: [DockGraphDrawing?] = []
        let controller = DockIconController(defaults: defaults) { rendered.append($0) }
        controller.update(cpu: 1, memory: 0.5, at: 0, visible: true)
        #expect(rendered.isEmpty)
        Settings.dockGraphMode.set(.cpu, in: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(rendered.last??.mode == .cpu)
        let count = rendered.count
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(rendered.count == count)
        controller.setPaused(true)
        #expect(rendered.last??.paused == true)
        Settings.dockGraphMode.set(.off, in: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(rendered.last == .some(nil))
    }

    @Test func rendererCachesItsBitmapAndOffModeIsTheDefault() throws {
        var feed = DockGraphFeed()
        feed.setMode(.cpu)
        feed.add(cpu: 0.4, memory: 0.6, at: 0)
        let value = feed.drawing(at: 0)
        let drawing = try #require(value)
        let first = DockIconRenderer.image(drawing)
        #expect(first === DockIconRenderer.image(drawing))
        #expect(first.representations.first?.pixelsWide == 256)
        #expect(first.representations.first?.pixelsHigh == 256)
        #expect(Settings.dockGraphMode.defaultValue == .off)
    }
}
