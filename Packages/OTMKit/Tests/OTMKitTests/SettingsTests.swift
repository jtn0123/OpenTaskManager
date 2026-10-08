import Foundation
@testable import OTMKit
import Testing

struct SettingsTests {
    // These are the keys and effective defaults before the typed registry. Changing them needs a migration.
    private let legacyDefaults: [String: SettingDefault] = [
        "appsFilter": .string("All"),
        "showAppsInspector": .bool(true),
        "overviewShowsCores": .bool(true),
        "cpuGraphScale": .string("auto"),
        "startupFilter": .string("All"),
        "showStartupInspector": .bool(true),
        "performanceShowsDiskImages": .bool(false),
        "fitsCollectedGraphData": .bool(true),
        "networkByProcess": .bool(false),
        "cpuGraphMode": .string("cores"),
        "cpuLargerGraphs": .bool(false),
        "showMenuBarExtra": .bool(true),
        "streamGraphs": .bool(true),
        "sidebarHidden": .bool(false),
        "globalHotKeyEnabled": .bool(true),
        "heatmap": .bool(true),
        "historyHardwareShown": .bool(false),
        "historyHardwareChart": .string("cores"),
        "historyCompareDetails": .bool(false),
        "threadSortKey": .string("cpu"),
        "hiddenConnectionColumns": .string(""),
        "driversFilter": .string("Third party"),
        "showDriversInspector": .bool(true),
        "groupMemberSort": .string("cpu"),
        "historyRange": .integer(3_600),
        "historyFitsRecording": .bool(false),
        "storageChangesOnly": .bool(true),
        "processViewMode": .string("grouped"),
        "processSortKey": .string("cpu"),
        "processSortAscending": .bool(false),
        "showInspector": .bool(true),
        "hiddenProcessColumns": .string("kind,threads,topTier,wakeups"),
        "page": .string("Overview"),
        "peakSystemWatts": .double(0),
        "measuresProcessEnergy": .absent,
        "reportsProcessGPU": .absent,
        "reportsProcessNeuralMemory": .absent,
        "updateSpeed": .double(1),
        "includeSystemProcesses": .bool(true),
        "cpuRelativeToSystem": .bool(true),
        "sustainedMinutes": .integer(2),
        "captureSpikes": .bool(false),
        "spikesSeen": .date(.distantPast),
        "systemReportFormat": .string("markdown"),
        "graphPalette": .string("standard"),
        "benchmarkComparePicks": .stringLists([:]),
        "benchmarkTrendBaselines": .strings([:]),
        "benchmarkSuiteIncludesDisk": .bool(false),
        "benchmarkSuiteIncludesNetwork": .bool(false),
        "appsInspectorWidth": .double(320),
        "startupInspectorWidth": .double(320),
        "driversInspectorWidth": .double(320),
        "processInspectorWidth": .double(320),
        "connectionInspectorWidth": .double(320),
        "benchmarkCardShowsRuns.cpu": .bool(false),
        "benchmarkCardShowsRuns.sustained": .bool(false),
        "benchmarkCardShowsRuns.gpu": .bool(false),
        "benchmarkCardShowsRuns.disk": .bool(false),
        "benchmarkCardShowsRuns.network": .bool(false),
        "graphColor.cpu": .absent,
        "graphColor.memory": .absent,
        "graphColor.gpu": .absent,
        "graphColor.disk": .absent,
        "graphColor.network": .absent,
        "graphColor.power": .absent,
    ]

    @Test func everyKeyAndDefaultIsPinnedAndUnique() {
        let keys = Settings.all.map(\.key)
        #expect(keys.count == Set(keys).count)
        #expect(keys.count == legacyDefaults.count)
        #expect(Set(keys) == Set(legacyDefaults.keys))
        for setting in Settings.all {
            #expect(legacyDefaults[setting.key] == setting.defaultValue)
            #expect(!setting.meaning.isEmpty)
            #expect(!setting.valueType.isEmpty)
            #expect(!setting.storedType.isEmpty)
        }
        #expect(Set(Settings.graphColorOverrides.keys) == Set(GraphPalette.Role.resources))
        #expect(BenchmarkKind.allCases.map { Settings.benchmarkCardShowsRuns($0).key } == [
            "benchmarkCardShowsRuns.cpu", "benchmarkCardShowsRuns.sustained", "benchmarkCardShowsRuns.gpu",
            "benchmarkCardShowsRuns.disk", "benchmarkCardShowsRuns.network",
        ])
    }

    @Test func choicesKeepTheirRawPropertyListEncoding() throws {
        try withDefaults { defaults in
            checkChoices(Settings.appsFilter, in: defaults)
            checkChoices(Settings.startupFilter, in: defaults)
            checkChoices(Settings.driversFilter, in: defaults)
            checkChoices(Settings.cpuGraphScale, in: defaults)
            checkChoices(Settings.historyHardwareChart, in: defaults)
            checkChoices(Settings.threadSortKey, in: defaults)
            checkChoices(Settings.groupMemberSort, in: defaults)
            checkChoices(Settings.historyRange, in: defaults)
            checkChoices(Settings.processViewMode, in: defaults)
            checkChoices(Settings.processSortKey, in: defaults)
            checkChoices(Settings.page, in: defaults)
            checkChoices(Settings.updateSpeed, in: defaults)
            checkChoices(Settings.systemReportFormat, in: defaults)
            checkChoices(Settings.graphPalette, in: defaults)
        }
    }

    @Test func invalidChoicesUseTheOriginalDefaults() throws {
        try withDefaults { defaults in
            defaults.set("unknown", forKey: "processViewMode")
            defaults.set("unknown", forKey: "page")
            defaults.set("unknown", forKey: "graphPalette")
            defaults.set(0, forKey: "updateSpeed")
            defaults.set(123, forKey: "historyRange")
            #expect(Settings.processViewMode.get(in: defaults) == .grouped)
            #expect(Settings.page.get(in: defaults) == .overview)
            #expect(Settings.graphPalette.get(in: defaults) == .standard)
            #expect(Settings.updateSpeed.get(in: defaults) == .normal)
            #expect(Settings.historyRange.get(in: defaults) == .hour)
        }
    }

    @Test func scalarValuesReadOldWritesAndWriteNativeValues() throws {
        try withDefaults { defaults in
            checkNative(Settings.showMenuBarExtra, sample: false, in: defaults)
            checkNative(Settings.processSortAscending, sample: true, in: defaults)
            checkNative(Settings.peakSystemWatts, sample: 123.5, in: defaults)
            checkNative(Settings.appsInspectorWidth, sample: 411.25, in: defaults)
            checkNative(Settings.sustainedMinutes, sample: 5, in: defaults)
            checkNative(Settings.cpuLargerGraphs, sample: true, in: defaults)
            checkNative(Settings.cpuGraphMode, sample: "overall", in: defaults)
            checkNative(Settings.spikesSeen, sample: Date(timeIntervalSince1970: 1_700_000_000), in: defaults)
            checkNative(Settings.benchmarkComparePicks, sample: ["cpu": ["cpu-1", "cpu-2"]], in: defaults)
            checkNative(Settings.benchmarkTrendBaselines, sample: ["gpu": "gpu-3"], in: defaults)
        }
    }

    @Test func capabilityFlagsKeepUnknownSeparateFromFalse() throws {
        try withDefaults { defaults in
            for key in [Settings.measuresProcessEnergy, Settings.reportsProcessGPU, Settings.reportsProcessNeuralMemory] {
                #expect(key.get(in: defaults) == nil)
                defaults.set(false, forKey: key.key)
                #expect(key.get(in: defaults) == false)
                key.set(true, in: defaults)
                #expect(defaults.object(forKey: key.key) as? Bool == true)
                key.set(nil, in: defaults)
                #expect(defaults.object(forKey: key.key) == nil)
                #expect(key.get(in: defaults) == nil)
            }
        }
    }

    @Test func colorOverridesRemainHexStringsAndResetRemovesThem() throws {
        try withDefaults { defaults in
            for key in Settings.graphColorOverrides.values {
                #expect(key.get(in: defaults) == nil)
                defaults.set("A1B2C3", forKey: key.key)
                #expect(key.get(in: defaults) == "A1B2C3")
                key.set("123456", in: defaults)
                #expect(defaults.string(forKey: key.key) == "123456")
                key.remove(in: defaults)
                #expect(defaults.object(forKey: key.key) == nil)
                #expect(key.get(in: defaults) == nil)
            }
        }
    }

    @Test func columnChoicesKeepCommaSeparatedEncoding() throws {
        try withDefaults { defaults in
            defaults.set("threads,+power", forKey: "hiddenProcessColumns")
            let process = Settings.hiddenProcessColumns.get(in: defaults)
            #expect(process.columns == [.threads])
            #expect(process.shownAnyway == [.power])
            Settings.hiddenProcessColumns.set(process, in: defaults)
            #expect(defaults.string(forKey: "hiddenProcessColumns") == "+power,threads")
            defaults.set("pid,protocol,process", forKey: "hiddenConnectionColumns")
            let connection = Settings.hiddenConnectionColumns.get(in: defaults)
            #expect(connection.columns == [.pid, .transport])
            Settings.hiddenConnectionColumns.set(connection, in: defaults)
            #expect(defaults.string(forKey: "hiddenConnectionColumns") == "pid,protocol")
            Settings.hiddenProcessColumns.remove(in: defaults)
            Settings.hiddenConnectionColumns.remove(in: defaults)
            #expect(Settings.hiddenProcessColumns.get(in: defaults) == .defaults)
            #expect(Settings.hiddenConnectionColumns.get(in: defaults) == HiddenConnectionColumns())
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "OpenTaskManager.SettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func checkChoices<Value, Stored>(_ key: SettingKey<Value, Stored>, in defaults: UserDefaults)
    where Value: RawRepresentable & CaseIterable & Equatable, Value.RawValue == Stored, Stored: Equatable {
        #expect(key.get(in: defaults) == key.defaultValue)
        for choice in Value.allCases {
            #expect(key.value(from: choice.rawValue) == choice)
            #expect(key.storedValue(choice) == choice.rawValue)
            defaults.set(choice.rawValue, forKey: key.key)
            #expect(key.get(in: defaults) == choice)
            key.set(choice, in: defaults)
            #expect(defaults.object(forKey: key.key) as? Stored == choice.rawValue)
        }
        key.remove(in: defaults)
        #expect(key.get(in: defaults) == key.defaultValue)
    }

    private func checkNative<Value>(_ key: SettingKey<Value, Value>, sample: Value, in defaults: UserDefaults)
    where Value: SettingStorage & Equatable {
        #expect(key.get(in: defaults) == key.defaultValue)
        defaults.set(sample, forKey: key.key)
        #expect(key.get(in: defaults) == sample)
        key.set(sample, in: defaults)
        #expect(defaults.object(forKey: key.key) as? Value == sample)
        key.remove(in: defaults)
        #expect(key.get(in: defaults) == key.defaultValue)
    }
}
