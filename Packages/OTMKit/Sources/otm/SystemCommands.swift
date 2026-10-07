import Foundation
import OTMKit

// `otm netconfig` and `otm hardware`: parts of the System page, read the
// same way and printed like `otm system report`, identifiers left out
// unless --all.

/// `otm netconfig [--all] [--json]`: the network cards (ports, the
/// configuration, mounted shares) and the firewall's card.
func netconfigCommand(_ options: Options) async {
    async let reading = FirewallReader.read()
    let ports = SystemInfoReader.readNetwork()
    let configuration = NetworkConfigurationReader.read()
    let firewall = await reading
    if options.json {
        guard let data = try? SystemReportDocument.networkJSON(ports, configuration: configuration, firewall: firewall,
                                                               includeIdentifiers: options.all) else {
            fail("could not encode JSON")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(SystemReport.networkText(ports, configuration: configuration, firewall: firewall, includeIdentifiers: options.all),
              terminator: "")
    }
}

/// `otm hardware [--all] [--json]`: the memory details and the
/// Controllers and Readers card, from one `system_profiler` run.
func hardwareCommand(_ options: Options) {
    let hardware = HardwareInventoryReader.read()
    if options.json {
        guard let data = try? SystemReportDocument.hardwareJSON(hardware, includeIdentifiers: options.all) else {
            fail("could not encode JSON")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(SystemReport.hardwareText(hardware, includeIdentifiers: options.all), terminator: "")
    }
}
