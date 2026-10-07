import Darwin
import Foundation
import SystemConfiguration

/// A user account from the directory (`getpwuid_r`).
public struct UserAccount: Sendable, Hashable {
    public let uid: UInt32
    public let name: String
    /// The full name from `pw_gecos`, nil when it's empty or just repeats the login name.
    public let fullName: String?
    public let homeDirectory: String?
}

/// A login recorded in utmpx: the GUI console, a Terminal tab, or an SSH session.
public struct LoginSession: Sendable, Hashable, Identifiable {
    public var id: String { "\(pid)-\(line)" }
    public let user: String
    /// The terminal line: "console" for the GUI login, "ttys003" for a terminal.
    public let line: String
    /// Where a remote session came from; nil for local ones.
    public let host: String?
    public let loginTime: Date
    public let pid: Int32

    public init(user: String, line: String, host: String?, loginTime: Date, pid: Int32) {
        self.user = user
        self.line = line
        self.host = host
        self.loginTime = loginTime
        self.pid = pid
    }

    public var isConsole: Bool { line == "console" }

    /// Where the session is: "Console", "ttys003", or "ttys004 from 192.168.1.20".
    public var place: String {
        if isConsole { return "Console" }
        guard let host else { return line }
        return "\(line) from \(host)"
    }
}

/// The user at the screen, as macOS reports it.
public struct ConsoleUser: Sendable, Hashable {
    public let name: String
    public let uid: UInt32
}

public enum UserAccounts {
    public static func account(uid: UInt32) -> UserAccount? {
        var size = max(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)), 4096)
        // A directory-service account can outgrow the suggested buffer; grow it and retry.
        for _ in 0..<4 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: size)
            let (status, account) = buffer.withUnsafeMutableBufferPointer { storage -> (Int32, UserAccount?) in
                let status = getpwuid_r(uid, &record, storage.baseAddress, storage.count, &result)
                guard status == 0, result != nil else { return (status, nil) }
                // The record's strings point into `storage`, so copy them out here.
                let name = record.pw_name.map { String(cString: $0) } ?? String(uid)
                let gecos = record.pw_gecos.map { String(cString: $0) } ?? ""
                let home = record.pw_dir.map { String(cString: $0) }
                return (0, UserAccount(uid: uid, name: name, fullName: fullName(fromGecos: gecos, login: name),
                                       homeDirectory: home.flatMap { $0.isEmpty ? nil : $0 }))
            }
            if status == ERANGE {
                size *= 2
                continue
            }
            return account
        }
        return nil
    }

    /// The gecos field is "Full Name,office,work phone,home phone"; the full
    /// name is everything before the first comma.
    static func fullName(fromGecos gecos: String, login: String) -> String? {
        let name = gecos.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return name.isEmpty || name == login ? nil : name
    }

    /// Up to two initials for an avatar: "Justin Example" → "JE", "_windowserver" → "W".
    public static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = (words.count > 1 ? [words.first, words.last] : [words.first]).compactMap { $0?.first }
        return letters.map { String($0).uppercased() }.joined()
    }

    /// The user signed in at the screen. nil at the login window.
    public static func consoleUser() -> ConsoleUser? {
        var uid: uid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? {
            return consoleUser(name: name, uid: uid)
        }
        // Without configd, whoever owns the console device is signed in.
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return nil }
        return consoleUser(name: account(uid: info.st_uid)?.name ?? String(info.st_uid), uid: info.st_uid)
    }

    /// The login window owns the console between sessions; that isn't a person signing in.
    static func consoleUser(name: String, uid: UInt32) -> ConsoleUser? {
        guard !name.isEmpty, name != "loginwindow", uid != 0 else { return nil }
        return ConsoleUser(name: name, uid: uid)
    }

    private static let utmpxLock = NSLock()

    /// Current logins from utmpx, oldest first.
    public static func sessions() -> [LoginSession] {
        // getutxent walks one shared cursor, so only one reader may use it at a time.
        utmpxLock.lock()
        defer { utmpxLock.unlock() }
        setutxent()
        defer { endutxent() }
        var sessions: [LoginSession] = []
        while let entry = getutxent() {
            let record = entry.pointee
            guard Int32(record.ut_type) == USER_PROCESS else { continue }
            let user = string(record.ut_user)
            guard !user.isEmpty else { continue }
            let host = string(record.ut_host)
            sessions.append(LoginSession(
                user: user,
                line: string(record.ut_line),
                host: host.isEmpty ? nil : host,
                loginTime: Date(timeIntervalSince1970: Double(record.ut_tv.tv_sec) + Double(record.ut_tv.tv_usec) / 1_000_000),
                pid: record.ut_pid
            ))
        }
        return sessions.sorted { $0.loginTime < $1.loginTime }
    }

    /// Decodes a fixed-size, NUL-padded C character array.
    static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
