import Foundation
import Testing

@testable import AgenthesiaCore

struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09 08:53:20 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")

    private func short(_ seconds: Double) -> String {
        RelativeTime.short(from: now.addingTimeInterval(-seconds), to: now, locale: gb, timeZone: utc)
    }

    @Test(arguments: [
        (-30.0, "now"), (0.0, "now"), (59.9, "now"), (60.0, "1m"), (299.0, "4m"), (300.0, "5m"), (3599.0, "59m"),
        (3600.0, "1h"), (10_800.0, "3h"), (86_399.0, "23h"), (86_400.0, "1d"), (172_800.0, "2d"), (604_799.0, "6d"),
        (604_800.0, "1w"), (1_814_400.0, "3w"), (2_419_199.0, "3w"),
    ])
    func abbreviatesByLargestUnit(seconds: Double, expected: String) {
        #expect(short(seconds) == expected)
    }

    @Test func fallsBackToAShortDateFromFourWeeks() {
        #expect(short(2_419_200) == "11 Sep")
        let old = Date(timeIntervalSince1970: 1_728_734_400)  // 2024-10-12 12:00 UTC
        #expect(RelativeTime.short(from: old, to: now, locale: gb, timeZone: utc) == "12 Oct")
    }
}
