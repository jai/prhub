import Foundation
import PRKitCore
import Testing

/// A clock time follows the device's 24-Hour Time setting, which reaches `Locale.current` as its hour cycle
/// (`@hours=h23` here): a fixed 24-hour clock showed "14:32" beside a chat's "2:32 PM" on a Mac set to 12-hour time.
struct ThreadTimeFormatTests {
    private static let bangkok = TimeZone(identifier: "Asia/Bangkok") ?? .gmt
    /// 17:40 in Bangkok, 12 Nov 2026.
    private static let afternoon = Date(timeIntervalSince1970: 1_794_480_000)

    private func format(_ locale: String) -> ThreadTimeFormat {
        ThreadTimeFormat(timeZone: Self.bangkok, locale: Locale(identifier: locale))
    }

    @Test func aClockTimeFollowsTheTwentyFourHourSetting() {
        #expect(format("en_US@hours=h23").string(Self.afternoon, now: Self.afternoon) == "17:40")
        #expect(format("en_GB").string(Self.afternoon, now: Self.afternoon) == "17:40")
        let twelveHour = format("en_US").string(Self.afternoon, now: Self.afternoon)
        #expect(twelveHour.hasPrefix("5:40") && twelveHour.hasSuffix("PM"))
    }

    @Test func anotherDayAndARowShowTheDayWithTheSameClock() {
        let nextDay = Self.afternoon.addingTimeInterval(86_400)
        #expect(format("en_US@hours=h23").string(Self.afternoon, now: nextDay) == "12 Nov 17:40")
        #expect(format("en_US@hours=h23").rowTime(Self.afternoon, now: Self.afternoon.addingTimeInterval(3 * 3_600))
            == "3h · 17:40")
    }
}
