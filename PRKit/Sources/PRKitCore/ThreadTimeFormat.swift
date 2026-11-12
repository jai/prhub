import Foundation

/// Times on the Threads screen, in `timeZone`: clock times ("17:20", or "5:20 PM" where `locale` keeps 12-hour time:
/// the device's 24-Hour Time setting is in `Locale.current`), days ("25 Oct") and how long ago ("3h").
public struct ThreadTimeFormat: Sendable {
    public var timeZone: TimeZone = .current
    public var locale: Locale = .current

    public init(timeZone: TimeZone = .current, locale: Locale = .current) {
        self.timeZone = timeZone
        self.locale = locale
    }

    public static let lastDayWithAge = 7

    /// The clock time for today, the day and the clock time for any other day.
    public func string(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? time(date) : dateAndTime(date)
    }

    /// The day and the clock time ("25 Oct 17:20"), whatever the day.
    public func dateAndTime(_ date: Date) -> String {
        "\(day(date)) \(time(date))"
    }

    /// How long ago, compactly: "now" under a minute, "12m", "3h", "2d", and the date — "21 Oct" — once it is more
    /// than `lastDayWithAge` days.
    public func age(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default:
            let days = seconds / 86_400
            return days <= Self.lastDayWithAge ? "\(days)d" : day(date)
        }
    }

    /// The age read out: "just now" under a minute, "12m ago", "2d ago", and "on 21 Oct" once the age is a date.
    public func ago(_ date: Date, now: Date) -> String {
        let age = age(date, now: now)
        if age == "now" {
            return "just now"
        }
        return Int(now.timeIntervalSince(date)) / 86_400 > Self.lastDayWithAge ? "on \(age)" : "\(age) ago"
    }

    /// A row's time: "3h · 17:20" today, "2d · 25 Oct" another day, and the date alone once the age is a date.
    public func rowTime(_ date: Date, now: Date) -> String {
        let age = age(date, now: now)
        let clock = calendar.isDate(date, inSameDayAs: now) ? time(date) : day(date)
        return age == clock ? age : "\(age) · \(clock)"
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The system's short time in `locale`, so it follows the 24-Hour Time setting, as every other clock does.
    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: timeZone))
    }

    private func day(_ date: Date) -> String {
        date.formatted(style("\(day: .defaultDigits) \(month: .abbreviated)"))
    }

    private func style(_ format: Date.FormatString) -> Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(format: format, locale: locale, timeZone: timeZone, calendar: calendar)
    }
}
