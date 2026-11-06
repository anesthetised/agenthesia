import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor struct SessionRowTests {
    @Test func subtitleJoinsTheProjectAndTheReason() {
        #expect(SessionRow.subtitle(project: "agenthesia", reason: nil) == "agenthesia")
        #expect(SessionRow.subtitle(project: "agenthesia", reason: "Merged") == "agenthesia · Merged")
        #expect(
            SessionRow.subtitle(project: "agenthesia", reason: "Allow? Write a.txt +1")
                == "agenthesia · Allow? Write a.txt +1"
        )
        #expect(SessionRow.subtitle(project: nil, reason: "Starting") == "Starting")
        #expect(SessionRow.subtitle(project: nil, reason: nil) == nil)
    }

    @Test func tooltipHoldsTheWholeRow() {
        #expect(
            SessionRow.tooltip(title: "Fix the build", project: "agenthesia", reason: "Allow? Write a.txt")
                == "Fix the build\nagenthesia · Allow? Write a.txt"
        )
        #expect(SessionRow.tooltip(title: "New Session", project: nil, reason: nil) == "New Session")
    }

    @Test func rowReadsAsOneLabelWithTitleProjectReasonAndTime() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let label = SessionRow.accessibilityLabel(
            title: "Fix the build",
            project: "agenthesia",
            reason: "Allow? Write a.txt",
            status: .needsInput,
            lastActivity: now.addingTimeInterval(-180),
            now: now
        )
        #expect(label == "Fix the build, agenthesia, Allow? Write a.txt, last active 3m")
        // Without a reason the status symbol is named instead; idle and saved rows have none to name.
        #expect(
            SessionRow.accessibilityLabel(
                title: "Fix",
                project: "p",
                reason: nil,
                status: .working,
                lastActivity: now,
                now: now
            ) == "Fix, p, Working, last active now"
        )
        #expect(
            SessionRow.accessibilityLabel(
                title: "New Session",
                project: nil,
                reason: nil,
                status: .idle,
                lastActivity: nil,
                now: now
            ) == "New Session"
        )
    }

    @Test func theProjectGivesWayFirstDownToFortyPercent() {
        func widths(_ project: Double, _ reason: Double) -> [Double] {
            let fitted = SubtitleLayout.widths(project: project, reason: reason, available: 200)
            return [fitted.project, fitted.reason]
        }
        // Everything fits.
        #expect(widths(80, 100) == [80, 100])
        // A long project makes room for the reason, but keeps 40 % at most when the reason is long too.
        #expect(widths(150, 100) == [100, 100])
        #expect(widths(150, 190) == [80, 120])
        // A short project is never padded; the reason is cut at its tail.
        #expect(widths(50, 400) == [50, 150])
        #expect(widths(400, 400) == [80, 120])
        // A project alone is cut at the line's end.
        #expect(widths(400, 0) == [200, 0])
    }

    @Test func aLongReasonKeepsTheRowOneLineHigh() throws {
        _ = NSApplication.shared
        func height(reason: String?) -> CGFloat {
            let host = NSHostingView(
                rootView: SessionRow(
                    title: "Fix the build",
                    project: "a-rather-long-project-name",
                    reason: reason,
                    activity: .needsInput,
                    lastActivity: .now
                )
                .frame(width: 240)
            )
            return host.fittingSize.height
        }
        let short = height(reason: "Finished")
        #expect(short > 0)
        #expect(height(reason: "Allow? " + String(repeating: "a very long tool title ", count: 12)) == short)
    }

    @Test func theReasonFollowsATruncatedProjectWithoutAGap() async throws {
        _ = NSApplication.shared
        final class Frames { var project = CGRect.zero, reason = CGRect.zero }
        let frames = Frames()
        let host = NSHostingView(
            rootView: SubtitleLayout {
                Text("agh-m15g-check-project").lineLimit(1)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named("line"))
                    } action: {
                        frames.project = $0
                    }
                Text(" · Prompt failed").lineLimit(1)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named("line"))
                    } action: {
                        frames.reason = $0
                    }
            }
            .coordinateSpace(.named("line"))
            .font(.caption)
            .frame(width: 140, alignment: .leading)
        )
        host.frame = CGRect(x: 0, y: 0, width: 140, height: 20)
        for _ in 0..<20 where frames.reason == .zero {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        // The project is cut, and the reason starts where its text ends, not where its share would.
        #expect(frames.project.width > 0 && frames.project.width < 140 * 0.6)
        #expect(abs(frames.reason.minX - frames.project.maxX) < 1)
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
