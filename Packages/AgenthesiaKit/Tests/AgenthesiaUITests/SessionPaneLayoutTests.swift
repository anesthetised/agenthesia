import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// `RootView` hosted at the widths real windows have: 740 pt is the window minimum (ADR-0039 amendment).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SessionPaneLayoutTests {
    struct Fixture {
        let inspector: SessionInspectorTests.Fixture
        let model: SessionWindowModel
        let view: NSHostingView<RootView>
        let window: NSWindow

        @MainActor func close() {
            model.close()
            window.close()
            try? FileManager.default.removeItem(at: inspector.directory)
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

    /// A MockAgent session with a file to open, shown in a window `width` points wide.
    private func fixture(width: CGFloat) async throws -> Fixture {
        let inspector = try await SessionInspectorTests().fixture(git: false)
        let working = URL(filePath: inspector.record.workingDirectory)
        try "hello\n".write(to: working.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: inspector.model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        let fixture = Fixture(inspector: inspector, model: inspector.model, view: view, window: window)
        for _ in 0..<20 { await settle() }
        return fixture
    }

    private func openFilePane(_ fixture: Fixture) async {
        await fixture.model.files.open(path: "notes.txt", in: fixture.inspector.record.id)
        for _ in 0..<20 { await settle() }
    }

    private func closeFilePane(_ fixture: Fixture) async {
        fixture.model.files.closeDocument()
        for _ in 0..<20 { await settle() }
    }

    /// The transcript's width in points, nil while it is not on screen.
    private func transcriptWidth(_ fixture: Fixture) -> CGFloat? {
        func find(_ view: NSView) -> TranscriptScrollView? {
            if let found = view as? TranscriptScrollView { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(fixture.view)?.frame.width
    }

    /// The transcript is usable and inside the window: it keeps its minimum width and is not pushed off an edge.
    private func expectTranscriptUsable(_ fixture: Fixture, _ step: String) {
        func find(_ view: NSView) -> TranscriptScrollView? {
            if let found = view as? TranscriptScrollView { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let transcript = find(fixture.view) else {
            Issue.record("no transcript \(step)")
            return
        }
        let frame = transcript.convert(transcript.bounds, to: nil)
        let window = fixture.window.contentLayoutRect
        #expect(frame.width >= DetailPanes.transcriptMinWidth, "transcript is \(frame.width) pt wide \(step)")
        #expect(frame.minX >= window.minX - 1 && frame.maxX <= window.maxX + 1, "transcript is clipped \(step)")
    }

    private func setInspector(_ shown: Bool, _ fixture: Fixture) async {
        fixture.model.showingInspector = shown
        for _ in 0..<20 { await settle() }
    }

    /// Visits the four states of (inspector, file pane) along all eight transitions between them.
    @Test(arguments: [740, 1000, 1400])
    func everyCombinationOfInspectorAndFilePaneLaysOut(width: Double) async throws {
        let fixture = try await fixture(width: CGFloat(width))
        defer { fixture.close() }
        expectTranscriptUsable(fixture, "at \(width) pt, inspector shown")
        await openFilePane(fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, inspector and file pane")
        await setInspector(false, fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, file pane only")
        await closeFilePane(fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, neither")
        await setInspector(true, fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, inspector only")
        await setInspector(false, fixture)
        await openFilePane(fixture)
        await setInspector(true, fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, both again")
        await closeFilePane(fixture)
        expectTranscriptUsable(fixture, "at \(width) pt, inspector again")
    }

    @Test func resizingWithBothPanesOpenKeepsTheTranscriptUsable() async throws {
        let fixture = try await fixture(width: 1400)
        defer { fixture.close() }
        await openFilePane(fixture)
        for width in [1300, 1100, 740, 1000, 1400] as [CGFloat] {
            fixture.window.setContentSize(.init(width: width, height: 700))
            for _ in 0..<20 { await settle() }
            expectTranscriptUsable(fixture, "after resizing to \(width) pt")
        }
    }

    @Test(arguments: [740, 1000])
    func startingASessionFromTheLaunchFormShowsTheInspector(width: Double) async throws {
        let fixture = try await fixture(width: CGFloat(width))
        defer { fixture.close() }
        fixture.model.showingSetup = true
        for _ in 0..<20 { await settle() }
        fixture.model.showingSetup = false
        for _ in 0..<20 { await settle() }
        expectTranscriptUsable(fixture, "after leaving the launch form at \(width) pt")
    }
}

@MainActor struct DetailPanesTests {
    @Test func everythingFitsInAWideColumn() {
        let panes = DetailPanes(width: 900, filePane: true, inspector: true)
        #expect(panes.showsFilePane && panes.showsInspector)
    }

    @Test func theInspectorGivesWayBeforeTheFilePane() {
        // 240 transcript + 240 file pane fit, the inspector's 220 pt on top do not.
        let narrow = DetailPanes(width: 500, filePane: true, inspector: true)
        #expect(narrow.showsFilePane && !narrow.showsInspector)
        #expect(DetailPanes(width: 700, filePane: true, inspector: true).showsInspector)
        #expect(!DetailPanes(width: 699, filePane: true, inspector: true).showsInspector)
    }

    @Test func theFilePaneGivesWayWhenItDoesNotFitBesideTheTranscript() {
        let panes = DetailPanes(width: 479, filePane: true, inspector: true)
        #expect(!panes.showsFilePane)
        // Without the file pane the inspector fits again: 240 + 220.
        #expect(panes.showsInspector)
    }

    @Test func theInspectorNeedsRoomBesideTheTranscript() {
        #expect(DetailPanes(width: 460, filePane: false, inspector: true).showsInspector)
        #expect(!DetailPanes(width: 459, filePane: false, inspector: true).showsInspector)
    }

    @Test func panesTheUserDidNotAskForStayHidden() {
        let panes = DetailPanes(width: 2000, filePane: false, inspector: false)
        #expect(!panes.showsFilePane && !panes.showsInspector)
        #expect(!DetailPanes(width: 2000, filePane: false, inspector: false).showsInspector)
    }

    @Test func anUnmeasuredColumnShowsEverythingAsked() {
        let panes = DetailPanes(width: .infinity, filePane: true, inspector: true)
        #expect(panes.showsFilePane && panes.showsInspector)
    }
}
