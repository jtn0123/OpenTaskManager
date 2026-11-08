/// Only string values from the launch argument domain. Saved preferences
/// belong to their stores, so a request to start a test never persists.
public enum LaunchOptions {
    public static func string(_ key: String, in argumentDomain: [String: Any]) -> String? {
        argumentDomain[key] as? String
    }

    /// A resource may appear briefly on the way to the requested detail.
    /// Only that detail starts its test; with none requested, the CPU does.
    public static func startsTest(on resource: String, in argumentDomain: [String: Any]) -> Bool {
        string("openSpeedTest", in: argumentDomain) == "start" && (string("openResource", in: argumentDomain) ?? "cpu") == resource
    }
}
