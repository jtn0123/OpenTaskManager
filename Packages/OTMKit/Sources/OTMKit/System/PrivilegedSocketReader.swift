import Foundation

/// Reads every process's sockets once as root: macOS's own administrator
/// prompt, through `osascript`'s `do shell script … with administrator
/// privileges`, runs lsof and nothing else. Nothing is installed and nothing
/// stays running; each read asks again (macOS may let a few minutes pass
/// without asking twice).
public enum PrivilegedSocketReader {
    public enum Outcome: Sendable {
        case read(PrivilegedSocketRead)
        /// The prompt was cancelled, or the calling task was.
        case cancelled
        case failed(String)
    }

    /// Every TCP and UDP socket (`-i`), with numeric addresses and ports,
    /// whole command names and no warnings, as fields.
    static let command = "/usr/sbin/lsof -w -n -P +c 0 -i -F pcuLftPnT"

    /// The AppleScript that asks for the password with `prompt` and runs
    /// `command`, keeping its line endings (AppleScript otherwise turns them into returns).
    static func script(prompt: String) -> String {
        let prompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges without altering line endings"
    }

    /// Asks, then reads, off the main actor. Waits up to `timeout` seconds
    /// for the password and the read; cancelling the task stops both.
    public static func read(prompt: String, timeout: TimeInterval = 300) async -> Outcome {
        let result = await CommandRunner.cancellableExecute("/usr/bin/osascript", ["-e", script(prompt: prompt)], timeout: timeout)
        guard let result else {
            return Task.isCancelled ? .cancelled : .failed("The password prompt or the read didn't finish.")
        }
        return outcome(status: result.status, output: result.text, readAt: Date())
    }

    /// What `osascript` printed, as an outcome. A cancelled prompt is
    /// AppleScript error -128; other errors read as their message, without
    /// osascript's position and number ("0:149: execution error: … (-60005)").
    static func outcome(status: Int32, output: String, readAt: Date) -> Outcome {
        guard status != 0 else { return .read(PrivilegedSocketRead(lsofFields: output, readAt: readAt)) }
        var message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasSuffix("(-128)") { return .cancelled }
        if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
        if let number = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { message.removeSubrange(number) }
        return .failed(message.isEmpty ? "The read failed." : message)
    }
}
