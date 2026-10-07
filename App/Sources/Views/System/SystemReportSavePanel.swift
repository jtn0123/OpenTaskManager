import AppKit
import OTMKit
import UniformTypeIdentifiers

/// Save Report…'s panel: the usual save panel with a format menu (Markdown
/// or JSON) and an option to include identifiers, which starts off every
/// time, since a saved report is often one to share.
@MainActor
enum SystemReportSavePanel {
    enum Format: String, CaseIterable {
        case markdown, json

        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .json: "JSON"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
            case .json: .json
            }
        }
    }

    struct Choice {
        var url: URL
        var format: Format
        var includeIdentifiers: Bool
    }

    /// The format picked last time.
    private static let formatKey = "systemReportFormat"

    /// Asks where to save, as a sheet on the front window. Nil when cancelled.
    static func choose(name: String) async -> Choice? {
        let panel = NSSavePanel()
        let format = Format(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .markdown
        let options = SaveOptions(panel: panel, format: format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = name + "." + (format.contentType.preferredFilenameExtension ?? "md")
        panel.message = "Saves this page: hardware, displays, storage, network, attached devices, battery, software and security."
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(options.format.rawValue, forKey: formatKey)
        return Choice(url: url, format: options.format, includeIdentifiers: options.includesIdentifiers)
    }

    /// Writes the report off the main actor; says so if it can't.
    static func write(_ report: SystemReportDocument, as choice: Choice) async {
        let url = choice.url
        do {
            let data = switch choice.format {
            case .markdown: Data(report.markdown(includeIdentifiers: choice.includeIdentifiers).utf8)
            case .json: try report.json(includeIdentifiers: choice.includeIdentifiers)
            }
            try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
        } catch {
            let alert = NSAlert()
            alert.messageText = "The report couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// The panel's accessory controls. The format menu swaps the file's
/// extension as it changes. The compact panel doesn't widen for its
/// accessory, so what the identifiers are goes on a line under the checkbox.
@MainActor
private final class SaveOptions: NSObject {
    private let panel: NSSavePanel
    private let formatMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let identifiers = NSButton(checkboxWithTitle: "Include identifiers", target: nil, action: nil)

    var format: SystemReportSavePanel.Format {
        SystemReportSavePanel.Format.allCases[max(formatMenu.indexOfSelectedItem, 0)]
    }

    var includesIdentifiers: Bool { identifiers.state == .on }

    init(panel: NSSavePanel, format: SystemReportSavePanel.Format) {
        self.panel = panel
        super.init()
        formatMenu.addItems(withTitles: SystemReportSavePanel.Format.allCases.map(\.title))
        formatMenu.selectItem(at: SystemReportSavePanel.Format.allCases.firstIndex(of: format) ?? 0)
        formatMenu.target = self
        formatMenu.action = #selector(formatChanged)
        identifiers.state = .off
        identifiers.toolTip = "The serial number, hardware UUID, device serial numbers, MAC, Bluetooth and IP addresses, "
            + "routers, DNS servers, search domains and proxy hosts. Leave it off for a report you'll share."
        identifiers.setAccessibilityLabel("Include identifiers (serial numbers, UUIDs, addresses)")
        let note = NSTextField(labelWithString: "Serial numbers, UUIDs, addresses")
        // 12 pt like the app's other explanations; the 11 pt small size is for metadata.
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.setAccessibilityElement(false)
        // Lines the note up with the checkbox's title.
        let noteRow = NSStackView(views: [note])
        noteRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let formatRow = NSStackView(views: [NSTextField(labelWithString: "Format:"), formatMenu])
        formatRow.spacing = 8
        let stack = NSStackView(views: [formatRow, identifiers, noteRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: identifiers)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.setFrameSize(stack.fittingSize)
        panel.accessoryView = stack
        panel.allowedContentTypes = [format.contentType]
    }

    @objc private func formatChanged() {
        panel.allowedContentTypes = [format.contentType]
    }
}
