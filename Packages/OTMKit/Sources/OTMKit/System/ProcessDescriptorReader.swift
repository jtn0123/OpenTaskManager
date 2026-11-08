import Darwin
import Foundation

/// Shared kernel reads for the inspector and the two descriptor walks.
/// Buffers grow only a bounded number of times as processes open descriptors.
enum ProcessDescriptorReader {
    // MARK: - Kernel reads

    static func allPIDs() -> [Int32]? {
        // The PID array is aligned and each call receives its byte capacity.
        let stride = MemoryLayout<Int32>.stride
        let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(estimate) / stride + 64)
        for _ in 0..<3 {
            let written = pids.withUnsafeMutableBytes {
                unsafe proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
            }
            guard written > 0 else { return nil }
            if Int(written) < pids.count * stride { return Array(pids.prefix(Int(written) / stride)) }
            // A full buffer may omit processes started since the estimate.
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
        errno = EAGAIN
        return nil
    }

    /// Fills `buffer` with the process's descriptors and returns how many
    /// there are, growing the buffer when it's too small. Nil with `errno`
    /// set when the process can't be read.
    static func listDescriptors(of pid: Int32, into buffer: inout [proc_fdinfo]) -> Int? {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let stride = MemoryLayout<proc_fdinfo>.stride
        for _ in 0..<3 {
            errno = 0
            let written = buffer.withUnsafeMutableBytes {
                unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if written == 0, errno == 0 { return 0 }
            guard written > 0 else { return nil }
            // A full buffer may have cut the list short; ask for the real size.
            guard Int(written) >= buffer.count * stride else { return Int(written) / stride }
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return nil }
            buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: max(Int(needed) / stride + 32, buffer.count * 2))
        }
        errno = EAGAIN
        return nil
    }

    /// The process's name and when it started, from the one record
    /// `proc_name` reads the name from, so the start time takes no extra call.
    struct Description {
        let name: String
        let start: Date?
        let path: String?
        let uid: UInt32?
    }

    static func describe(_ pid: Int32) -> Description {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return Description(name: "PID \(pid)", start: nil, path: nil, uid: nil)
        }
        let name = text(info.pbi_name)
        let shown = name.isEmpty ? text(info.pbi_comm) : name
        let start = ProcessIdentity.startTime(microseconds: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { unsafe proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let executable = length > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return Description(name: shown.isEmpty ? "PID \(pid)" : shown, start: start, path: executable, uid: info.pbi_uid)
    }

    /// A kernel record's fixed-size C string, up to its first NUL.
    static func text<Characters>(_ characters: Characters) -> String {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        withUnsafeBytes(of: characters) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func vnode(pid: Int32, fd: Int32) -> vnode_fdinfowithpath? {
        // The kernel borrows this aligned local record for its exact byte size.
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard unsafe proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        return info
    }

    static func socket(pid: Int32, fd: Int32) -> socket_fdinfo? {
        // The kernel borrows this aligned local record for its exact byte size.
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard unsafe proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        return info
    }

    static func currentDirectory(of pid: Int32) -> proc_vnodepathinfo? {
        // The kernel borrows this aligned local record for its exact byte size.
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
