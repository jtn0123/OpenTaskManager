import Foundation

/// Values passed on the command line (`--args -openResource memory`), for
/// opening the app in a known state for screenshots. Read from the argument
/// domain only, so they never stick in saved settings.
enum LaunchArgument {
    static func string(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
}
