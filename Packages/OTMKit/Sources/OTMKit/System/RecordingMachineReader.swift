import Foundation

extension RecordingMachine {
    /// This Mac, for a recording made here: a few sysctls and one
    /// IORegistry entry, cheap enough to read at each export.
    public static func current() -> RecordingMachine {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return RecordingMachine(
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            modelName: SystemInfoReader.readMarketingName(),
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown chip",
            memory: ProcessInfo.processInfo.physicalMemory,
            macOSVersion: SystemFacts.productVersion(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion),
            macOSBuild: Sysctl.string("kern.osversion")
        )
    }
}
