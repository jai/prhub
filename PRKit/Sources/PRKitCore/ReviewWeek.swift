import Foundation

/// The working week a review is due in, as the Worker's `reviewDueAt` counts it: one working day from when the reviewer
/// could first see the request, so one sent at night or at the weekend gets the whole next working day. Used when the
/// Worker has no SLA of its own (`REVIEW_SLA_*` unset, as on hosted PRHub): the phone's time zone, Monday to Friday,
/// 09:00 to 18:00.
public struct ReviewWeek: Sendable {
    public var calendar: Calendar
    public var startHour: Int
    public var endHour: Int
    /// `Calendar` weekdays: Sunday is 1.
    public var weekdays: Set<Int>

    public init(calendar: Calendar, startHour: Int = 9, endHour: Int = 18, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.calendar = calendar
        self.startHour = startHour
        self.endHour = endHour
        self.weekdays = weekdays
    }

    public static var local: ReviewWeek { ReviewWeek(calendar: .current) }

    public func dueAt(requestedAt: Date) -> Date? {
        let hour = calendar.component(.hour, from: requestedAt)
        var start = requestedAt
        if !isWorkday(requestedAt) || hour < startHour || hour >= endHour {
            var day = calendar.startOfDay(for: requestedAt)
            if hour >= startHour, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                day = next
            }
            day = nextWorkday(from: day)
            guard let opens = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) else {
                return nil
            }
            start = opens
        }
        return calendar.date(byAdding: .day, value: 1, to: start).map(nextWorkday)
    }

    private func isWorkday(_ date: Date) -> Bool {
        weekdays.contains(calendar.component(.weekday, from: date))
    }

    private func nextWorkday(from date: Date) -> Date {
        var date = date
        for _ in 0..<7 where !isWorkday(date) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
}
