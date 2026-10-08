import OTMKit
import SwiftUI

/// The page the window shows. Each running copy keeps its own: it starts at
/// the saved page, or the one `--args -openPage <name>` (or `-page <name>`)
/// names, and saves every change for the next launch, but never follows
/// another copy's. Read through `@AppStorage("page")`, a `-page` launch
/// argument pinned the setting for the whole run, so the sidebar highlighted
/// a click and the page stayed put; and every running copy followed the page
/// the last one saved.
@MainActor @Observable
final class PageSelection {
    static let shared = PageSelection()

    @ObservationIgnored private let defaults: UserDefaults

    var page: Page {
        didSet {
            if page != oldValue { Settings.page.set(page, in: defaults) }
        }
    }

    /// `arguments` is the launch argument domain, which only names the
    /// starting page; `defaults` holds the saved one.
    init(defaults: UserDefaults = .standard, arguments: [String: Any] = LaunchArgument.domain) {
        self.defaults = defaults
        let named = LaunchOptions.string("openBenchmarkGuided", in: arguments).map { _ in "Performance" }
            ?? LaunchOptions.string("openPage", in: arguments) ?? LaunchOptions.string(Settings.page.key, in: arguments)
        page = Page.starting(openPage: named, savedPage: defaults.string(forKey: Settings.page.key))
    }
}

/// The window's page, for a view to read or change: `@CurrentPage private var page`.
@MainActor @propertyWrapper
struct CurrentPage: DynamicProperty {
    private let selection = PageSelection.shared

    var wrappedValue: Page {
        get { selection.page }
        nonmutating set { selection.page = newValue }
    }

    var projectedValue: Binding<Page> {
        Binding(get: { selection.page }, set: { selection.page = $0 })
    }
}
