import Foundation

/// Every persisted preference, with its existing key and property-list encoding.
public enum Settings {
    public static let appsFilter = SettingKey<AppsFilter, String>(
        "appsFilter", default: .all, meaning: "Apps shown in the Apps table."
    )
    public static let showAppsInspector = SettingKey<Bool, Bool>(
        "showAppsInspector", default: true, meaning: "Whether the Apps inspector is enabled."
    )
    public static let overviewShowsCores = SettingKey<Bool, Bool>(
        "overviewShowsCores", default: true, meaning: "Whether Overview shows its per-core graphs."
    )
    public static let cpuGraphScale = SettingKey<CPUGraphScale, String>(
        "cpuGraphScale", default: .auto, meaning: "Shared scale for CPU graphs."
    )
    public static let startupFilter = SettingKey<StartupFilter, String>(
        "startupFilter", default: .all, meaning: "Launch items shown in the Startup table."
    )
    public static let showStartupInspector = SettingKey<Bool, Bool>(
        "showStartupInspector", default: true, meaning: "Whether the Startup inspector is enabled."
    )
    public static let performanceShowsDiskImages = SettingKey<Bool, Bool>(
        "performanceShowsDiskImages", default: false, meaning: "Whether Performance lists disk images."
    )
    public static let fitsCollectedGraphData = SettingKey<Bool, Bool>(
        "fitsCollectedGraphData", default: true, meaning: "Whether Performance graphs fit the data collected so far."
    )
    public static let networkByProcess = SettingKey<Bool, Bool>(
        "networkByProcess", default: false, meaning: "Whether network usage is grouped by process instead of app."
    )
    public static let cpuLargerGraphs = SettingKey<Bool, Bool>(
        "cpuLargerGraphs", default: false, meaning: "Whether the CPU per-core tiles fill the main graph area."
    )
    public static let cpuGraphMode = SettingKey<String, String>(
        "cpuGraphMode", default: "cores", meaning: "Form of the main CPU graph."
    )
    public static let showMenuBarExtra = SettingKey<Bool, Bool>(
        "showMenuBarExtra", default: true, meaning: "Whether the menu bar item is shown."
    )
    public static let streamGraphs = SettingKey<Bool, Bool>(
        "streamGraphs", default: true, meaning: "Whether live graphs scroll smoothly."
    )
    public static let sidebarHidden = SettingKey<Bool, Bool>(
        "sidebarHidden", default: false, meaning: "Whether the user hid the sidebar in a wide window."
    )
    public static let globalHotKeyEnabled = SettingKey<Bool, Bool>(
        "globalHotKeyEnabled", default: true, meaning: "Whether the global hot key is enabled."
    )
    public static let heatmap = SettingKey<Bool, Bool>(
        "heatmap", default: true, meaning: "Whether process cells are tinted by their usage."
    )
    public static let historyHardwareShown = SettingKey<Bool, Bool>(
        "historyHardwareShown", default: false, meaning: "Whether History shows its hardware charts."
    )
    public static let historyHardwareChart = SettingKey<HistoryHardwareChart, String>(
        "historyHardwareChart", default: .cores, meaning: "Hardware chart picked in History."
    )
    public static let historyCompareDetails = SettingKey<Bool, Bool>(
        "historyCompareDetails", default: false, meaning: "Whether History comparison details are expanded."
    )
    public static let threadSortKey = SettingKey<ThreadSortKey, String>(
        "threadSortKey", default: .cpu, meaning: "Sort order of the process inspector thread table."
    )
    public static let hiddenConnectionColumns = SettingKey<HiddenConnectionColumns, String>(
        "hiddenConnectionColumns", default: HiddenConnectionColumns(), meaning: "Connection columns hidden by the user."
    )
    public static let driversFilter = SettingKey<DriversFilter, String>(
        "driversFilter", default: .thirdParty, meaning: "Extensions shown in the Drivers table."
    )
    public static let showDriversInspector = SettingKey<Bool, Bool>(
        "showDriversInspector", default: true, meaning: "Whether the Drivers inspector is enabled."
    )
    public static let groupMemberSort = SettingKey<GroupMemberSort, String>(
        "groupMemberSort", default: .cpu, meaning: "Sort order of the process inspector group table."
    )
    public static let historyRange = SettingKey<HistoryRange, Int>(
        "historyRange", default: .hour, meaning: "Time range shown in History."
    )
    public static let historyFitsRecording = SettingKey<Bool, Bool>(
        "historyFitsRecording", default: false, meaning: "Whether History fits the full opened recording."
    )
    public static let storageSchedules = SettingKey<DiskScanSchedules, String>(
        "storageSchedules", default: DiskScanSchedules(), meaning: "Opt-in Storage scans while the app is running."
    )
    public static let storageScheduleNotifications = SettingKey<Bool, Bool>(
        "storageScheduleNotifications", default: false, meaning: "Notify when a scheduled scan finds big growth."
    )
    public static let storageChangesOnly = SettingKey<Bool, Bool>(
        "storageChangesOnly", default: true, meaning: "Whether Storage lists only changed entries in Changes mode."
    )
    public static let processViewMode = SettingKey<ProcessViewMode, String>(
        "processViewMode", default: .grouped, meaning: "Grouping of the process table."
    )
    public static let processSortKey = SettingKey<ProcessSortKey, String>(
        "processSortKey", default: .cpu, meaning: "Sort column of the process table."
    )
    public static let processSortAscending = SettingKey<Bool, Bool>(
        "processSortAscending", default: false, meaning: "Whether the process sort runs from smallest to largest."
    )
    public static let showInspector = SettingKey<Bool, Bool>(
        "showInspector", default: true, meaning: "Whether the Processes inspector is enabled."
    )
    public static let hiddenProcessColumns = SettingKey<HiddenProcessColumns, String>(
        "hiddenProcessColumns", default: .defaults, meaning: "Process columns hidden or explicitly shown by the user."
    )
    public static let page = SettingKey<Page, String>(
        "page", default: .overview, meaning: "Page saved for the next launch; read once by each running copy."
    )
    public static let peakSystemWatts = SettingKey<Double, Double>(
        "peakSystemWatts", default: 0, meaning: "Highest whole-system power draw seen on this Mac."
    )
    public static let measuresProcessEnergy = SettingKey<Bool?, Bool?>(
        "measuresProcessEnergy", default: nil, meaning: "Whether process energy is available; unknown before sampling."
    )
    public static let reportsProcessGPU = SettingKey<Bool?, Bool?>(
        "reportsProcessGPU", default: nil, meaning: "Whether process GPU time is reported; unknown before sampling."
    )
    public static let reportsProcessNeuralMemory = SettingKey<Bool?, Bool?>(
        "reportsProcessNeuralMemory", default: nil, meaning: "Whether process Neural Engine memory is reported; unknown before sampling."
    )
    public static let updateSpeed = SettingKey<UpdateSpeed, Double>(
        "updateSpeed", default: .normal, meaning: "Interval between live samples."
    )
    public static let includeSystemProcesses = SettingKey<Bool, Bool>(
        "includeSystemProcesses", default: true, meaning: "Whether the sampler includes restricted system processes."
    )
    public static let cpuRelativeToSystem = SettingKey<Bool, Bool>(
        "cpuRelativeToSystem", default: true, meaning: "Whether process CPU is shown as a share of the whole CPU."
    )
    public static let sustainedMinutes = SettingKey<Int, Int>(
        "sustainedMinutes", default: 2, meaning: "Length of the next sustained CPU run in minutes."
    )
    public static let captureSpikes = SettingKey<Bool, Bool>(
        "captureSpikes", default: false, meaning: "Whether spikes are captured automatically."
    )
    public static let spikesSeen = SettingKey<Date, Date>(
        "spikesSeen", default: .distantPast, meaning: "When the spike capture list was last opened."
    )
    public static let systemReportFormat = SettingKey<SystemReportFormat, String>(
        "systemReportFormat", default: .markdown, meaning: "Format last picked for Save Report."
    )
    public static let graphPalette = SettingKey<GraphPalette.Preset, String>(
        "graphPalette", default: .standard, meaning: "Graph color preset."
    )
    public static let benchmarkComparePicks = SettingKey<[String: [String]], [String: [String]]>(
        "benchmarkComparePicks", default: [:], meaning: "Run IDs picked for comparison, by benchmark kind."
    )
    public static let benchmarkTrendBaselines = SettingKey<[String: String], [String: String]>(
        "benchmarkTrendBaselines", default: [:], meaning: "Baseline run ID for each benchmark trend."
    )
    public static let benchmarkSuiteIncludesDisk = SettingKey<Bool, Bool>(
        "benchmarkSuiteIncludesDisk", default: false, meaning: "Whether Run all includes the disk speed test."
    )
    public static let benchmarkSuiteIncludesNetwork = SettingKey<Bool, Bool>(
        "benchmarkSuiteIncludesNetwork", default: false, meaning: "Whether Run all includes the Internet quality test."
    )
    public static let appsInspectorWidth = SettingKey<Double, Double>(
        "appsInspectorWidth", default: 320, meaning: "Preferred width of the apps inspector in points."
    )
    public static let startupInspectorWidth = SettingKey<Double, Double>(
        "startupInspectorWidth", default: 320, meaning: "Preferred width of the startup inspector in points."
    )
    public static let driversInspectorWidth = SettingKey<Double, Double>(
        "driversInspectorWidth", default: 320, meaning: "Preferred width of the drivers inspector in points."
    )
    public static let processInspectorWidth = SettingKey<Double, Double>(
        "processInspectorWidth", default: 320, meaning: "Preferred width of the process inspector in points."
    )
    public static let connectionInspectorWidth = SettingKey<Double, Double>(
        "connectionInspectorWidth", default: 320, meaning: "Preferred width of the connection inspector in points."
    )
    public static let benchmarkCardShowsRunsCpu = SettingKey<Bool, Bool>(
        "benchmarkCardShowsRuns.cpu", default: false, meaning: "Whether the cpu benchmark card shows saved runs."
    )
    public static let benchmarkCardShowsRunsSustained = SettingKey<Bool, Bool>(
        "benchmarkCardShowsRuns.sustained", default: false, meaning: "Whether the sustained benchmark card shows saved runs."
    )
    public static let benchmarkCardShowsRunsGpu = SettingKey<Bool, Bool>(
        "benchmarkCardShowsRuns.gpu", default: false, meaning: "Whether the gpu benchmark card shows saved runs."
    )
    public static let benchmarkCardShowsRunsDisk = SettingKey<Bool, Bool>(
        "benchmarkCardShowsRuns.disk", default: false, meaning: "Whether the disk benchmark card shows saved runs."
    )
    public static let benchmarkCardShowsRunsNetwork = SettingKey<Bool, Bool>(
        "benchmarkCardShowsRuns.network", default: false, meaning: "Whether the network benchmark card shows saved runs."
    )
    public static let graphColorCpu = SettingKey<String?, String?>(
        "graphColor.cpu", default: nil, meaning: "Custom cpu graph color as a hex string; absent uses the preset."
    )
    public static let graphColorMemory = SettingKey<String?, String?>(
        "graphColor.memory", default: nil, meaning: "Custom memory graph color as a hex string; absent uses the preset."
    )
    public static let graphColorGpu = SettingKey<String?, String?>(
        "graphColor.gpu", default: nil, meaning: "Custom gpu graph color as a hex string; absent uses the preset."
    )
    public static let graphColorDisk = SettingKey<String?, String?>(
        "graphColor.disk", default: nil, meaning: "Custom disk graph color as a hex string; absent uses the preset."
    )
    public static let graphColorNetwork = SettingKey<String?, String?>(
        "graphColor.network", default: nil, meaning: "Custom network graph color as a hex string; absent uses the preset."
    )
    public static let graphColorPower = SettingKey<String?, String?>(
        "graphColor.power", default: nil, meaning: "Custom power graph color as a hex string; absent uses the preset."
    )

    public static let graphColorOverrides: [GraphPalette.Role: SettingKey<String?, String?>] = [
        .cpu: graphColorCpu,
        .memory: graphColorMemory,
        .gpu: graphColorGpu,
        .disk: graphColorDisk,
        .network: graphColorNetwork,
        .power: graphColorPower,
    ]

    public static func benchmarkCardShowsRuns(_ kind: BenchmarkKind) -> SettingKey<Bool, Bool> {
        switch kind {
        case .cpu: benchmarkCardShowsRunsCpu
        case .sustained: benchmarkCardShowsRunsSustained
        case .gpu: benchmarkCardShowsRunsGpu
        case .disk: benchmarkCardShowsRunsDisk
        case .network: benchmarkCardShowsRunsNetwork
        }
    }

    /// Expanded keys, including every supported color override and per-test disclosure.
    public static let all: [SettingDescriptor] = [
        appsFilter.descriptor,
        showAppsInspector.descriptor,
        overviewShowsCores.descriptor,
        cpuGraphScale.descriptor,
        startupFilter.descriptor,
        showStartupInspector.descriptor,
        performanceShowsDiskImages.descriptor,
        fitsCollectedGraphData.descriptor,
        networkByProcess.descriptor,
        cpuGraphMode.descriptor,
        cpuLargerGraphs.descriptor,
        showMenuBarExtra.descriptor,
        streamGraphs.descriptor,
        sidebarHidden.descriptor,
        globalHotKeyEnabled.descriptor,
        heatmap.descriptor,
        historyHardwareShown.descriptor,
        historyHardwareChart.descriptor,
        historyCompareDetails.descriptor,
        threadSortKey.descriptor,
        hiddenConnectionColumns.descriptor,
        driversFilter.descriptor,
        showDriversInspector.descriptor,
        groupMemberSort.descriptor,
        historyRange.descriptor,
        historyFitsRecording.descriptor,
        storageChangesOnly.descriptor,
        storageSchedules.descriptor,
        storageScheduleNotifications.descriptor,
        processViewMode.descriptor,
        processSortKey.descriptor,
        processSortAscending.descriptor,
        showInspector.descriptor,
        hiddenProcessColumns.descriptor,
        page.descriptor,
        peakSystemWatts.descriptor,
        measuresProcessEnergy.descriptor,
        reportsProcessGPU.descriptor,
        reportsProcessNeuralMemory.descriptor,
        updateSpeed.descriptor,
        includeSystemProcesses.descriptor,
        cpuRelativeToSystem.descriptor,
        sustainedMinutes.descriptor,
        captureSpikes.descriptor,
        spikesSeen.descriptor,
        systemReportFormat.descriptor,
        graphPalette.descriptor,
        benchmarkComparePicks.descriptor,
        benchmarkTrendBaselines.descriptor,
        benchmarkSuiteIncludesDisk.descriptor,
        benchmarkSuiteIncludesNetwork.descriptor,
        appsInspectorWidth.descriptor,
        startupInspectorWidth.descriptor,
        driversInspectorWidth.descriptor,
        processInspectorWidth.descriptor,
        connectionInspectorWidth.descriptor,
        benchmarkCardShowsRunsCpu.descriptor,
        benchmarkCardShowsRunsSustained.descriptor,
        benchmarkCardShowsRunsGpu.descriptor,
        benchmarkCardShowsRunsDisk.descriptor,
        benchmarkCardShowsRunsNetwork.descriptor,
        graphColorCpu.descriptor,
        graphColorMemory.descriptor,
        graphColorGpu.descriptor,
        graphColorDisk.descriptor,
        graphColorNetwork.descriptor,
        graphColorPower.descriptor,
    ]
}
