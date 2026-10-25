import Darwin
import Foundation
@testable import OTMKit
import Testing

struct OwnerQueryTests {
    @Test func parsesLocalPorts() throws {
        #expect(try OwnerQuery.parse("8080") == .port(8080, nil))
        #expect(try OwnerQuery.parse(":8080") == .port(8080, nil))
        #expect(try OwnerQuery.parse("tcp:8080") == .port(8080, .tcp))
        #expect(try OwnerQuery.parse(" UDP:5353 \n") == .port(5353, .udp))
        #expect(try OwnerQuery.parse("65535") == .port(65535, nil))
    }

    @Test(arguments: ["", "  ", "0", ":0", "65536", "tcp:-1", "udp:", ":abc", "tcp:80:90", "tcp: 80", "999999999999999999999"])
    func rejectsInvalidQueries(input: String) {
        #expect(throws: OwnerLookupError.self) { try OwnerQuery.parse(input) }
    }

    @Test func parsesPathsWithoutInterpretingEmbeddedNumbersAsPorts() throws {
        #expect(try OwnerQuery.parse("./8080") == .path("./8080"))
        #expect(try OwnerQuery.parse("/tmp/file 8080") == .path("/tmp/file 8080"))
        #expect(try OwnerQuery.parse("/tmp/a file ") == .path("/tmp/a file "))
        #expect(try OwnerQuery.parse("~/Documents") == .path("~/Documents"))
        #expect(try OwnerQuery.parse("file:///tmp/a%20file") == .path("/tmp/a file"))
    }
}

struct OwnerMatchingTests {
    private let identity = OwnerFileIdentity(device: 4, inode: 123)

    private func file(_ path: String, device: Int64 = 4, inode: UInt64 = 123) -> OwnerDescriptor {
        OwnerDescriptor(kind: .file, descriptor: 7, path: path, fileIdentity: OwnerFileIdentity(device: device, inode: inode))
    }

    private func socket(_ proto: SocketInfo.TransportProtocol, local: Int, remote: Int? = nil) -> OwnerDescriptor {
        OwnerDescriptor(kind: .socket, descriptor: 9,
                        socket: SocketInfo(proto: proto, localAddress: "::1", localPort: local,
                                           remoteAddress: remote == nil ? nil : "127.0.0.1", remotePort: remote, state: "LISTEN"))
    }

    @Test func fileMatchesIdentityEvenWithAnotherPath() {
        let target = OwnerTarget.file(path: "/tmp/query", identity: identity)
        let hardLink = file("/elsewhere/hard-link")
        let descriptors = [hardLink, file("/tmp/query", device: 5), file("/tmp/query", inode: 124),
                           OwnerDescriptor(kind: .file, descriptor: 8, path: "/tmp/query"),
                           OwnerDescriptor(kind: .currentDirectory, path: "/tmp/query", fileIdentity: identity)]
        #expect(target.matches(in: descriptors) == [hardLink])
        #expect(target.matches(file("", inode: 123)), "an unlinked file still matches its inode")
    }

    @Test func folderIncludesItselfDescendantsAndWorkingDirectoriesButNotSiblings() {
        let target = OwnerTarget.folder(path: "/Work", volumeDevice: nil)
        let child = file("/Work/child/file")
        let directory = OwnerDescriptor(kind: .currentDirectory, path: "/Work/current")
        let descriptors = [file("/Work"), child, directory, file("/Workshop/file"), file("/Elsewhere"),
                           OwnerDescriptor(kind: .file, descriptor: 10, path: "")]
        #expect(target.matches(in: descriptors) == [descriptors[0], child, directory])
        #expect(!target.matches(socket(.tcp, local: 8080)))
        #expect(OwnerTarget.folder(path: "/", volumeDevice: nil).matches(file("/any/path")))
    }

    @Test func volumeAlsoIncludesPathsOnItsDevice() {
        let target = OwnerTarget.folder(path: "/Volumes/Disk", volumeDevice: 4)
        #expect(target.matches(file("/another/spelling")))
        #expect(!target.matches(file("/elsewhere", device: 5)))
        #expect(target.matches(file("/Volumes/Disk/child", device: 5)))
        #expect(target.volumeNote != nil)
        #expect(OwnerTarget.folder(path: "/Work", volumeDevice: nil).volumeNote == nil)
    }

    @Test func portMatchesLocalEndpointAndOptionalProtocol() {
        let tcp = socket(.tcp, local: 8080)
        let udp = socket(.udp, local: 8080)
        let descriptors = [tcp, udp, socket(.tcp, local: 50000, remote: 8080), socket(.unix, local: 8080), file("8080")]
        #expect(OwnerTarget.port(8080, nil).matches(in: descriptors) == [tcp, udp])
        #expect(OwnerTarget.port(8080, .tcp).matches(in: descriptors) == [tcp])
        #expect(OwnerTarget.port(8080, .udp).matches(in: descriptors) == [udp])
        #expect(tcp.label == "FD 9 · TCP [::1]:8080 (LISTEN)")
    }

    @Test func emptyResultKeepsCoverageAndQueryScope() throws {
        let result = OwnerLookupResult(target: .port(8080, .tcp), processes: [], unreadableProcesses: 300,
                                       checkedProcesses: 200, totalProcesses: 500, duration: 0.025)
        #expect(result.emptyDescription.contains("200 processes"))
        #expect(result.emptyDescription.contains("TCP sockets on local port 8080"))
        #expect(result.unreadableDescription.contains("300 processes couldn't be checked"))
        let restored = try JSONDecoder().decode(OwnerLookupResult.self, from: JSONEncoder().encode(result))
        #expect(restored.unreadableProcesses == 300)
        #expect(restored.target == result.target)
    }
}

struct OwnerLookupLiveTests {
    @Test func findsOwnFileThroughAHardLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original")
        let link = folder.appendingPathComponent("different-name")
        try Data("owner lookup".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        let result = try OwnerLookup.search(link.path)
        let mine = try #require(result.processes.first { $0.identity.pid == getpid() })
        #expect(mine.identity == ProcessDetailReader.identity(of: getpid()))
        #expect(mine.identity.startTime != nil)
        let match = try #require(mine.matches.first { $0.descriptor == handle.fileDescriptor })
        var stats = stat()
        try #require(fstat(handle.fileDescriptor, &stats) == 0)
        #expect(match.fileIdentity == OwnerFileIdentity(device: Int64(stats.st_dev), inode: UInt64(stats.st_ino)))
        // macOS may report either hard link's path for the vnode; its inode
        // must still be the one held by the original open descriptor. The
        // kernel spells the temporary folder /private/var/…, which Foundation's
        // resolvingSymlinksInPath strips, so compare within the test's own folder.
        let reported = try #require(match.path)
        #expect(["original", "different-name"].contains { reported.hasSuffix("/\(folder.lastPathComponent)/\($0)") })
        #expect(!mine.name.isEmpty)
        #expect(mine.path != nil)
        #expect(!mine.user.isEmpty)
        #expect(result.checkedProcesses > 0)
    }

    @Test func findsOwnEphemeralLoopbackListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let result = try OwnerLookup.search("tcp:\(port)")
        let mine = try #require(result.processes.first { $0.identity.pid == getpid() })
        #expect(mine.identity == ProcessDetailReader.identity(of: getpid()))
        let match = try #require(mine.matches.first { $0.descriptor == fd })
        #expect(match.socket?.localPort == port)
        #expect(match.socket?.localAddress == "127.0.0.1")
        #expect(match.socket?.state == "LISTEN")
        #expect(match.socket?.proto == .tcp)
        #expect(result.duration >= 0)
    }
}
