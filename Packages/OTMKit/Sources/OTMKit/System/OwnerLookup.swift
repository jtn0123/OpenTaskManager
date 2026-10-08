import Darwin
import Foundation

public struct OwnerProcess: Sendable, Codable, Identifiable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let name: String
    public let path: String?
    public let user: String
    public let matches: [OwnerDescriptor]
}

public struct OwnerLookupResult: Sendable, Codable {
    public let target: OwnerTarget
    public let processes: [OwnerProcess]
    /// Includes partial reads; a match doesn't make the rest of a process's
    /// unreadable descriptors disappear from this count.
    public let unreadableProcesses: Int
    public let checkedProcesses: Int
    public let totalProcesses: Int
    public let duration: TimeInterval

    public var unreadableDescription: String {
        "\(unreadableProcesses) processes couldn't be checked (other users' and the system's)"
    }

    public var emptyDescription: String {
        "No matches found. Checked \(checkedProcesses) processes for \(target.checkedDescription)."
    }
}

/// One bounded walk per request. No timers, shell tools or sampler work.
/// Call off the main actor; the caller decides when another search is needed.
public enum OwnerLookup {
    public static func search(_ query: String) throws -> OwnerLookupResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let target = try resolve(OwnerQuery.parse(query))
        guard let pids = ProcessDescriptorReader.allPIDs() else { throw OwnerLookupError.processListUnavailable }
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        var owners: [OwnerProcess] = []
        var unreadable = 0
        var checked = 0
        var users: [UInt32: String] = [:]
        let livePIDs = pids.filter { $0 > 0 }
        for pid in livePIDs {
            let read = readProcess(pid, target: target, buffer: &buffer)
            if !read.complete { unreadable += 1 }
            if read.complete { checked += 1 }
            guard let identity = read.identity, !read.matches.isEmpty else { continue }
            let described = ProcessDescriptorReader.describe(pid)
            // A process can end while its descriptors are read. Never give its
            // results to a new process that macOS assigned the same PID.
            guard described.start == identity.startTime else { continue }
            let user = described.uid.map { uid in
                let name = users[uid] ?? UserAccounts.account(uid: uid)?.name ?? String(uid)
                users[uid] = name
                return name
            } ?? "Unavailable"
            owners.append(OwnerProcess(identity: identity, name: described.name, path: described.path, user: user,
                                       matches: read.matches))
        }
        owners.sort { $0.name == $1.name ? $0.identity.pid < $1.identity.pid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return OwnerLookupResult(target: target, processes: owners, unreadableProcesses: unreadable, checkedProcesses: checked,
                                 totalProcesses: livePIDs.count,
                                 duration: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
    }

    static func resolve(_ query: OwnerQuery) throws -> OwnerTarget {
        switch query {
        case let .port(port, proto): return .port(port, proto)
        case let .path(path):
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            var info = stat()
            // stat borrows this aligned local record for the call; it follows
            // the query's symlink, just as opening that file does.
            guard unsafe stat(url.path, &info) == 0 else { throw OwnerLookupError.unreadablePath(path) }
            let identity = OwnerFileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
            if info.st_mode & S_IFMT == S_IFDIR {
                let volume = MountTable.volume(at: url.path)
                let isVolume = volume.map {
                    URL(fileURLWithPath: $0.mountPoint).resolvingSymlinksInPath().path == url.path
                } ?? false
                return .folder(path: url.path, volumeDevice: isVolume ? identity.device : nil)
            }
            return .file(path: url.path, identity: identity)
        }
    }

    private struct ProcessRead {
        var identity: ProcessIdentity?
        var matches: [OwnerDescriptor] = []
        var complete = true
    }

    private static func readProcess(_ pid: Int32, target: OwnerTarget, buffer: inout [proc_fdinfo]) -> ProcessRead {
        var result = ProcessRead(identity: ProcessDetailReader.identity(of: pid))
        guard result.identity?.startTime != nil else {
            result.complete = false
            return result
        }
        if let count = ProcessDescriptorReader.listDescriptors(of: pid, into: &buffer) {
            for fd in buffer.prefix(count) {
                errno = 0
                let descriptor: OwnerDescriptor?
                switch (target, Int32(fd.proc_fdtype)) {
                case (.port, PROX_FDTYPE_SOCKET):
                    descriptor = ProcessInspector.socket(pid: pid, fd: fd.proc_fd).map {
                        OwnerDescriptor(kind: .socket, descriptor: fd.proc_fd, socket: $0.socket)
                    }
                case (.file, PROX_FDTYPE_VNODE), (.folder, PROX_FDTYPE_VNODE):
                    descriptor = ProcessDescriptorReader.vnode(pid: pid, fd: fd.proc_fd).map {
                        OwnerDescriptor(kind: .file, descriptor: fd.proc_fd, path: ProcessDescriptorReader.text($0.pvip.vip_path),
                                        fileIdentity: fileIdentity($0.pvip.vip_vi.vi_stat))
                    }
                default: continue
                }
                if let descriptor {
                    if target.matches(descriptor) { result.matches.append(descriptor) }
                } else if errno != EBADF && errno != ESRCH {
                    // A descriptor closed during the walk is ordinary churn;
                    // denied or otherwise unreadable records leave incomplete coverage.
                    result.complete = false
                }
            }
        } else {
            // The working directory can still be readable when the descriptor
            // table isn't. Keep any match while reporting incomplete coverage.
            result.complete = false
        }
        if target.isFolder {
            if let directory = ProcessDescriptorReader.currentDirectory(of: pid) {
                let descriptor = OwnerDescriptor(kind: .currentDirectory,
                                                 path: ProcessDescriptorReader.text(directory.pvi_cdir.vip_path),
                                                 fileIdentity: fileIdentity(directory.pvi_cdir.vip_vi.vi_stat))
                if target.matches(descriptor) { result.matches.append(descriptor) }
            } else {
                result.complete = false
            }
        }
        return result
    }

    private static func fileIdentity(_ stats: vinfo_stat) -> OwnerFileIdentity {
        OwnerFileIdentity(device: Int64(stats.vst_dev), inode: stats.vst_ino)
    }
}
