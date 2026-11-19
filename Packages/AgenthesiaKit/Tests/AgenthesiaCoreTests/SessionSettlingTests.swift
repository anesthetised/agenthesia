import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@Suite struct SessionSettlingTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 24 * 60 * 60

    private func settles(
        daysIdle: Double = 0,
        isLive: Bool = false,
        lastOutcome: WorktreeOutcome? = nil,
        settledAt: Date? = nil,
        archivedAt: Date? = nil
    ) -> Bool {
        let session = SessionRecord(
            projectID: UUID(),
            agentInstallID: UUID(),
            workingDirectory: "/tmp/tree",
            archivedAt: archivedAt,
            settledAt: settledAt,
            createdAt: now.addingTimeInterval(-30 * day)
        )
        return SessionSettling.settles(
            session,
            isLive: isLive,
            lastOutcome: lastOutcome,
            lastActivity: now.addingTimeInterval(-daysIdle * day),
            now: now
        )
    }

    @Test func aSessionInTheListStaysForSevenDaysOfQuiet() {
        #expect(!settles(daysIdle: 0))
        #expect(!settles(daysIdle: 6))
        #expect(settles(daysIdle: 7))
        #expect(settles(daysIdle: 8))
    }

    @Test func aMergedOrDiscardedWorktreeSettlesAtOnce() {
        #expect(settles(lastOutcome: .merged(commit: "abc", into: "main")))
        #expect(settles(lastOutcome: .discarded))
    }

    /// The caller passes no outcome when an Unsettle followed it, so the Unsettle's day counts.
    @Test func anUnsettleYesterdayKeepsTheSessionInTheList() {
        #expect(!settles(daysIdle: 1))
        #expect(settles(daysIdle: 8))
    }

    @Test func aLiveSessionNeverSettlesByItself() {
        #expect(!settles(daysIdle: 8, isLive: true))
        #expect(!settles(isLive: true, lastOutcome: .discarded))
    }

    @Test func aSettledSessionIsLeftAsItIs() {
        #expect(!settles(daysIdle: 8, settledAt: now.addingTimeInterval(-day)))
    }

    @Test func anArchivedSessionFollowsTheSameRule() {
        #expect(!settles(daysIdle: 6, archivedAt: now))
        #expect(settles(daysIdle: 8, archivedAt: now))
        #expect(settles(lastOutcome: .discarded, archivedAt: now))
    }

    @Test func aSessionWithoutEventsCountsFromItsStart() {
        let session = SessionRecord(
            projectID: UUID(),
            agentInstallID: UUID(),
            workingDirectory: "/tmp/tree",
            createdAt: now.addingTimeInterval(-6 * day)
        )
        #expect(!SessionSettling.settles(session, isLive: false, lastOutcome: nil, lastActivity: nil, now: now))
        #expect(
            SessionSettling.settles(
                session,
                isLive: false,
                lastOutcome: nil,
                lastActivity: nil,
                now: now.addingTimeInterval(day)
            )
        )
    }
}
