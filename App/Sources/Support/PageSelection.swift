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

    private static let key = "page"

    var page: Page {
        didSet {
            if page != oldValue { UserDefaults.standard.set(page.rawValue, forKey: Self.key) }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        let named = defaults.string(forKey: "openPage") ?? defaults.string(forKey: Self.key)
        page = named.flatMap(Page.init(rawValue:)) ?? .overview
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
