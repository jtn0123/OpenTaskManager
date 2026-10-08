import Foundation
import Testing
@testable import OTMKit

struct LaunchExitCodingTests {
    @Test func exitsRoundTripInTheExplicitPublicForm() throws {
        for value in [LaunchExitStatus.code(0), .code(1), .code(-11), .reason("pe")] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(LaunchExitStatus.self, from: data) == value)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object.count == 1)
            switch value {
            case let .code(code): #expect(object["code"] as? Int32 == code)
            case let .reason(reason): #expect(object["reason"] as? String == reason)
            }
        }
        let event = LaunchHistoryEvent(key: LaunchHistoryKey(label: "job", domain: "system"), time: .now, kind: .exited, exit: .code(1))
        let report = LaunchHistoryReport(coverage: [LaunchHistoryInterval(start: event.time, end: event.time)], events: [event])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any])
        #expect(Set(object.keys) == ["coverage", "events"])
        let coverage = try #require(object["coverage"] as? [[String: Any]])
        #expect(Set(coverage[0].keys) == ["start", "end"])
        let events = try #require(object["events"] as? [[String: Any]])
        let exit = try #require(events[0]["exit"] as? [String: Int])
        #expect(exit == ["code": 1])
    }

    @Test func rejectsSynthesizedMixedUnknownAndWrongTypedExits() {
        for text in [#"{"code":{"_0":1}}"#, #"{"reason":{"_0":"pe"}}"#, #"{"code":1,"reason":"pe"}"#,
                     #"{"code":1,"extra":true}"#, #"{"code":null}"#, #"{"code":"1"}"#, #"{"reason":1}"#, "{}", "1"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LaunchExitStatus.self, from: Data(text.utf8)) }
        }
    }
}
