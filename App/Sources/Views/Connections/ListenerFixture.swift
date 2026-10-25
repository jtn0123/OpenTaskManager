#if DEBUG
import Foundation
import OTMKit

/// Made-up listeners give screenshots a review to show without changing this Mac's baseline.
enum ListenerFixture {
    static func review() -> ListenerReview {
        let time = Date.now.addingTimeInterval(-3_600)
        let old = listener(path: "/Applications/Example Server.app/Contents/MacOS/Example Server", port: 8_080, address: "127.0.0.1")
        let replaced = listener(path: "/usr/local/bin/example-preview", port: 4_000, address: "127.0.0.1")
        let observations = [
            listener(path: old.identity.executable.path, port: 8_080, address: "0.0.0.0"),
            listener(path: old.identity.executable.path, port: 9_090, address: "127.0.0.1"),
            listener(path: "/Applications/Example Studio.app/Contents/MacOS/Example Studio", port: 4_000, address: "127.0.0.1"),
        ]
        var review = ListenerReview(baseline: ListenerBaseline(listeners: [old.identity, replaced.identity], at: time))
        review.record(observations, at: time.addingTimeInterval(1_800))
        return review
    }

    private static func listener(path: String, port: Int, address: String) -> ListenerObservation {
        let connection = Connection(id: .init(pid: 42, fd: 3, socket: UInt64(port)), processName: (path as NSString).lastPathComponent,
                                    transport: .tcp, family: .ipv4, local: Endpoint(address: address, port: port),
                                    remote: nil, tcpState: .listen)
        return ListenerObservation(identity: ListenerIdentity(executable: ListenerExecutable(path: path), transport: .tcp,
                                                              port: port, scope: ListenerBindScope(connection.local)),
                                   connection: connection)
    }
}
#endif
