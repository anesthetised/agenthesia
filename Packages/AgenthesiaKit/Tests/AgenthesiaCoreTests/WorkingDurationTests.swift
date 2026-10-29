import Testing

@testable import AgenthesiaCore

struct WorkingDurationTests {
    @Test(arguments: [
        (-5.0, "0s"), (0.0, "0s"), (0.9, "0s"), (12.0, "12s"), (59.9, "59s"), (60.0, "1m 0s"), (72.0, "1m 12s"),
        (3599.0, "59m 59s"), (3600.0, "1h 0m"), (3720.0, "1h 2m"), (36_000.0, "10h 0m"),
    ])
    func formatsWholeSecondsMinutesAndHours(interval: Double, expected: String) {
        #expect(WorkingDuration.format(interval) == expected)
    }
}
