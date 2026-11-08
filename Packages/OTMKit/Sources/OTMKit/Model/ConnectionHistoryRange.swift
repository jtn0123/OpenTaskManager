import Foundation

public enum ConnectionHistoryRange: String, Sendable, CaseIterable {
    case hour = "Last hour", today = "Today", week = "7 days"

    public func start(before end: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour: end.addingTimeInterval(-3_600)
        case .today: calendar.startOfDay(for: end)
        case .week: end.addingTimeInterval(-FlightRecorder.retention)
        }
    }
}
