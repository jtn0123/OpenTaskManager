import Foundation
@testable import OTMKit
import Testing

/// `networkQuality -c` on macOS 27 over Wi-Fi, with the long per-probe
/// latency arrays cut to a few entries.
private let fixture = """
{
  "base_rtt" : 17.809663772583008,
  "cli_options" : [
    "-c"
  ],
  "dl_bytes_transferred" : 988658122,
  "dl_flows" : 10,
  "dl_phase_duration" : 21.672860980033875,
  "dl_phase_end" : "2026-10-07 04:26:20.933",
  "dl_phase_start" : "2026-10-07 04:25:59.260",
  "dl_throughput" : 361439456,
  "draft_version" : 8,
  "end_date" : "2026-10-07 04:26:20.940",
  "il_h2_req_resp" : [ 12.910962104797363, 14.56904411315918 ],
  "il_tcp_handshake_443" : [ 13, 12 ],
  "il_tls_handshake" : [ 19, 23 ],
  "interface_name" : "en0",
  "lud_foreign_h2_req_resp" : [ 40, 62, 31 ],
  "lud_foreign_tcp_handshake_443" : [ 14, 42 ],
  "lud_foreign_tls_handshake" : [ 35, 26 ],
  "lud_self_h2_req_resp" : [ 29, 66, 21 ],
  "os_version" : "Version 27.2 (Build 26B5101f)",
  "other" : {
    "ecn_values" : { "ecn_classic" : 457 },
    "interface-type" : { "wifi" : 457 },
    "l4s_enablement" : { "enabled" : 457 },
    "protocols_seen" : { "h2" : 457 },
    "proxy_state" : { "not_proxied" : 457 },
    "rat" : { "unknown" : 457 }
  },
  "responsiveness" : 215.51217651367188,
  "start_date" : "2026-10-07 04:25:59.084",
  "test_endpoint" : "uslax1-edge-fx-023.aaplimg.com",
  "ul_bytes_transferred" : 842006528,
  "ul_flows" : 14,
  "ul_phase_duration" : 21.672860980033875,
  "ul_phase_end" : "2026-10-07 04:26:20.933",
  "ul_phase_start" : "2026-10-07 04:25:59.260",
  "ul_throughput" : 319803552
}
"""

/// The tool's usage text, which lists `-I` on releases that can bind to an interface.
private let usage = """
USAGE: networkQuality [-B <bonjour instance>] [-b] [-C <configuration_url>] [-c [optional filename]] [-d]
       [-f <comma-separated list>] [-h] [-I <network interface name>] [-k] [-p] [-r host] [-S <port>] [-s] [-u] [-v]
    -c[optional filename]: Produce computer-readable output. Will default to STDOUT if filename not specified
    -I: Bind test to interface (e.g., en0, pdp_ip0,...)
    -s: Run tests sequentially instead of parallel upload/download
"""

struct NetworkQualityTests {
    private let date = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func parsesTheMachineReadableOutput() throws {
        let result = try NetworkQuality.parse(fixture, requestedInterface: "en0", date: date)
        #expect(result.date == date)
        #expect(result.requestedInterface == "en0")
        #expect(result.interface == "en0")
        #expect(result.downloadBitsPerSecond == 361_439_456)
        #expect(result.uploadBitsPerSecond == 319_803_552)
        #expect(abs((result.responsiveness ?? 0) - 215.512) < 0.001)
        #expect(abs((result.idleLatency ?? 0) - 17.81) < 0.01)
        #expect(result.bytesTransferred == 988_658_122 + 842_006_528)
        #expect(result.endpoint == "uslax1-edge-fx-023.aaplimg.com")
        #expect(result.arguments == ["-c"])
        #expect(result.toolVersion == "Version 27.2 (Build 26B5101f)")
        #expect(result.downloadFlows == 10 && result.uploadFlows == 14)
        #expect(result.rating == .fair)
        #expect(result.historyKey == "en0")
        #expect(result.configurationSummary == "bound to en0 · parallel · 10 down, 14 up")
    }

    @Test func toleratesTextAroundTheJSONAndMissingFields() throws {
        // A download-only run (-u) on a release without the newer fields.
        let output = """
        warning: something the tool printed first
        { "dl_throughput": "52000000", "responsiveness": 1450, "cli_options": ["-c", "-u", "-s"] }
        """
        let result = try NetworkQuality.parse(output, requestedInterface: nil, date: date)
        #expect(result.downloadBitsPerSecond == 52_000_000)
        #expect(result.uploadBitsPerSecond == nil)
        #expect(result.bytesTransferred == nil)
        #expect(result.interface == nil)
        #expect(result.rating == .excellent)
        #expect(result.historyKey == "default")
        #expect(result.configurationSummary == "system route · sequential")
    }

    @Test func aRunWithoutMeasurementsFails() {
        let failed = """
        { "error_code": -1009, "error_domain": "NSURLErrorDomain", "interface_name": "en0", "dl_throughput": 0 }
        """
        #expect(throws: NetworkQualityError.failed("NSURLErrorDomain -1009")) {
            try NetworkQuality.parse(failed, requestedInterface: "en0", date: date)
        }
        #expect(throws: NetworkQualityError.failed(nil)) {
            try NetworkQuality.parse("{}", requestedInterface: nil, date: date)
        }
        #expect(throws: NetworkQualityError.failed(nil)) {
            try NetworkQuality.parse("networkQuality: not JSON at all", requestedInterface: nil, date: date)
        }
    }

    @Test func bindsToAnInterfaceOnlyWhereTheToolCan() {
        #expect(NetworkQuality.arguments(interface: "en0") == ["-c", "-I", "en0"])
        #expect(NetworkQuality.arguments(interface: nil) == ["-c"])
        #expect(NetworkQuality.supportsInterfaceOption(usage: usage))
        let older = usage.replacingOccurrences(of: "[-I <network interface name>] ", with: "")
            .replacingOccurrences(of: "    -I: Bind test to interface (e.g., en0, pdp_ip0,...)\n", with: "")
        #expect(!NetworkQuality.supportsInterfaceOption(usage: older))
    }

    @Test func ratesResponsivenessInPlainWords() {
        #expect(NetworkResponsiveness(rpm: 40) == .poor)
        #expect(NetworkResponsiveness(rpm: 199.9) == .poor)
        #expect(NetworkResponsiveness(rpm: 200) == .fair)
        #expect(NetworkResponsiveness(rpm: 650) == .good)
        #expect(NetworkResponsiveness(rpm: 1000) == .excellent)
        #expect(NetworkResponsiveness.poor < .excellent)
        #expect(NetworkResponsiveness.loadedLatency(rpm: 600) == 100)
        #expect(NetworkResponsiveness.loadedLatency(rpm: 0) == nil)
        for rating in NetworkResponsiveness.allCases {
            #expect(!rating.title.isEmpty && rating.summary.hasSuffix("."))
        }
    }

    @Test func resultsRoundTripThroughJSON() throws {
        let result = try NetworkQuality.parse(fixture, requestedInterface: "en0", date: date)
        let decoded = try JSONDecoder().decode(NetworkQualityResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(decoded.version == NetworkQualityResult.currentVersion)
    }
}
