import Foundation
import IOKit.ps

/// Cheap power reads for a due scan; this never starts the sampler or reads sensors.
public enum DiskScanScheduleReader {
    public static func conditions(idleSeconds: Double, anotherScanRunning: Bool) -> DiskScanEligibility {
        var charge: Double?
        // The retained info keeps each borrowed source description alive until its numbers are copied.
        if let info = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = unsafe IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                let description = unsafe IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
                guard description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description?[kIOPSCurrentCapacityKey] as? Double,
                      let maximum = description?[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
                charge = current / maximum
            }
        }
        return DiskScanEligibility(power: BenchmarkContextReader.powerSource(), charge: charge,
                                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   thermal: BenchmarkContextReader.thermalNow(), idleSeconds: idleSeconds,
                                   anotherScanRunning: anotherScanRunning)
    }

    /// No enumeration here. Reject protected paths before resolving links or checking access.
    public static func scopeFailure(path: String, home: String = NSHomeDirectory()) -> String? {
        if DiskScanScheduleSafety.refusal(path: path, home: home) != nil { return DiskScanScheduleSafety.permissionNeeded }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if DiskScanScheduleSafety.refusal(path: resolved, home: home) != nil { return DiskScanScheduleSafety.permissionNeeded }
        if path.hasPrefix("/Volumes/") {
            let mounts = MountTable.mountPoints()
            guard mounts.contains(where: { $0 != "/" && (path == $0 || path.hasPrefix($0 + "/")) }) else {
                return "Not mounted"
            }
        }
        var directory: ObjCBool = false
        // FileManager borrows the local flag only for this existence check.
        guard unsafe FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            return "Folder unavailable"
        }
        guard FileManager.default.isReadableFile(atPath: path) else { return DiskScanScheduleSafety.permissionNeeded }
        return nil
    }
}
