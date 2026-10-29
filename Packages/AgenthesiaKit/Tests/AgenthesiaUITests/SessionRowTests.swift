import Foundation
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor struct SessionRowTests {
    @Test func subtitleNamesTheProjectAndTheOutcome() {
        #expect(SessionRow.subtitle(project: "agenthesia", outcome: nil) == "agenthesia")
        #expect(
            SessionRow.subtitle(project: "agenthesia", outcome: .merged(commit: "abc", into: "main"))
                == "agenthesia · Merged"
        )
        #expect(SessionRow.subtitle(project: "agenthesia", outcome: .discarded) == "agenthesia · Discarded")
        #expect(SessionRow.subtitle(project: nil, outcome: nil) == nil)
    }

    @Test func rowReadsAsOneLabelWithTitleProjectStatusAndTime() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let label = SessionRow.accessibilityLabel(
            title: "Fix the build",
            subtitle: "agenthesia · Merged",
            status: .needsInput,
            started: now.addingTimeInterval(-300),
            now: now
        )
        #expect(label == "Fix the build, agenthesia · Merged, Needs input, 5m")
        #expect(
            SessionRow.accessibilityLabel(title: "New Session", subtitle: nil, status: .idle, started: nil, now: now)
                == "New Session"
        )
    }

    @Test func badgeTintFollowsTheNameHashAndIsStable() {
        #expect(ProjectBadgeView.tints.count == 8)
        for name in ["agenthesia", "my-project", "", "élan"] {
            let index = Int(ProjectBadge.hash(name) % 8)
            #expect(ProjectBadgeView.tint(for: name) == ProjectBadgeView.tints[index])
        }
        // "a" hashes to 0xaf63dc4c8601ec8c, whose low three bits are 4: orange.
        #expect(ProjectBadgeView.tint(for: "a") == .orange)
    }
}
