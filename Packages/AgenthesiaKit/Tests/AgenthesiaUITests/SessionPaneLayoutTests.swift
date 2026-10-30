import AppKit
import Foundation
import Rendering
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

    /// Waits until the panes the model asks for are on screen and their frames held still for one 20 ms step, or
    /// 400 ms at most; a fixed 400 ms per step kept the hosted tests near CI's process timeout.
    private func settle(_ fixture: Fixture) async {
        var previous: PaneFrames?
        for step in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            let current = frames(fixture)
            if step >= 2, current == previous, panesMatchTheModel(fixture, current) { return }
            previous = current
        }
    }

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
        await settle(fixture)
        return fixture
    }

    private func openFilePane(_ fixture: Fixture) async {
        await fixture.model.files.open(path: "notes.txt", in: fixture.inspector.record.id)
        await settle(fixture)
    }

    private func closeFilePane(_ fixture: Fixture) async {
        fixture.model.files.closeDocument()
        await settle(fixture)
    }

    /// The measurable frames of the detail column's panes, in window coordinates.
    private struct PaneFrames: Equatable {
        var transcript: CGRect?
        var filePane: CGRect?
        var inspector: CGRect?
    }

    /// Finds the panes by the AppKit views they contain: the transcript table, the file pane's source view and the
    /// inspector's tall scroll view. The window's content edge is the right edge of the detail column.
    private func frames(_ fixture: Fixture) -> PaneFrames {
        var found = PaneFrames()
        func visit(_ view: NSView) {
            let frame = view.convert(view.bounds, to: nil)
            if view is TranscriptScrollView {
                found.transcript = frame
            } else if view is SourceView {
                found.filePane = frame
            } else if String(describing: type(of: view)).hasSuffix("HostingScrollView"), frame.height > 300 {
                found.inspector = frame
            }
            view.subviews.forEach(visit)
        }
        visit(fixture.view)
        return found
    }

    /// Whether the visible panes are the ones `DetailPanes` shows for the measured column width.
    private func panesMatchTheModel(_ fixture: Fixture, _ found: PaneFrames) -> Bool {
        guard let transcript = found.transcript else { return false }
        let panes = DetailPanes(
            width: fixture.window.contentLayoutRect.maxX - transcript.minX,
            filePane: fixture.model.files.selectedPath != nil,
            inspector: fixture.model.showingInspector
        )
        return (found.filePane != nil) == panes.showsFilePane && (found.inspector != nil) == panes.showsInspector
    }

    /// Every pane fits: the transcript, file pane and inspector keep their minimum widths, follow each other
    /// without overlap, and the last one ends at the window's content edge (not short of it, not beyond it).
    /// Which panes are visible follows `DetailPanes` for the measured column width.
    private func expectPanesFit(_ fixture: Fixture, _ step: String) {
        let found = frames(fixture)
        guard let transcript = found.transcript else {
            Issue.record("no transcript \(step)")
            return
        }
        let edge = fixture.window.contentLayoutRect.maxX
        let panes = DetailPanes(
            width: edge - transcript.minX,
            filePane: fixture.model.files.selectedPath != nil,
            inspector: fixture.model.showingInspector
        )
        #expect((found.filePane != nil) == panes.showsFilePane, "file pane visibility \(step)")
        #expect((found.inspector != nil) == panes.showsInspector, "inspector visibility \(step)")
        let visible = [found.transcript, found.filePane, found.inspector].compactMap { $0 }
        #expect(
            transcript.width >= DetailPanes.transcriptMinWidth - 0.5,
            "transcript is \(transcript.width) pt \(step)"
        )
        if let file = found.filePane {
            #expect(file.width >= DetailPanes.filePaneMinWidth - 0.5, "file pane is \(file.width) pt \(step)")
        }
        if let inspector = found.inspector {
            #expect(
                inspector.width >= DetailPanes.inspectorMinWidth - 0.5,
                "inspector is \(inspector.width) pt \(step)"
            )
            #expect(
                inspector.width <= DetailPanes.inspectorMaxWidth + 0.5,
                "inspector is \(inspector.width) pt \(step)"
            )
        }
        for (left, right) in zip(visible, visible.dropFirst()) {
            #expect(left.maxX <= right.minX + 1.5, "panes overlap \(step)")
        }
        if let last = visible.last {
            #expect(abs(last.maxX - edge) <= 1.5, "last pane ends at \(last.maxX), the window at \(edge) \(step)")
        }
    }

    private func setInspector(_ shown: Bool, _ fixture: Fixture) async {
        fixture.model.showingInspector = shown
        await settle(fixture)
    }

    private func resize(_ width: CGFloat, _ fixture: Fixture) async {
        fixture.window.setContentSize(.init(width: width, height: 700))
        await settle(fixture)
    }

    /// Gives the inspector its 360 pt maximum, as dragging its edge does.
    private func widenInspector(_ fixture: Fixture) async {
        fixture.model.inspectorWidth = DetailPanes.inspectorMaxWidth
        await settle(fixture)
    }

    /// Visits the four states of (inspector, file pane) along all eight transitions between them.
    @Test(arguments: [740, 1400])
    func everyCombinationOfInspectorAndFilePaneLaysOut(width: Double) async throws {
        let fixture = try await fixture(width: CGFloat(width))
        defer { fixture.close() }
        expectPanesFit(fixture, "at \(width) pt, inspector shown")
        await openFilePane(fixture)
        expectPanesFit(fixture, "at \(width) pt, inspector and file pane")
        await setInspector(false, fixture)
        expectPanesFit(fixture, "at \(width) pt, file pane only")
        await closeFilePane(fixture)
        expectPanesFit(fixture, "at \(width) pt, neither")
        await setInspector(true, fixture)
        expectPanesFit(fixture, "at \(width) pt, inspector only")
        await setInspector(false, fixture)
        await openFilePane(fixture)
        await setInspector(true, fixture)
        expectPanesFit(fixture, "at \(width) pt, both again")
        await closeFilePane(fixture)
        expectPanesFit(fixture, "at \(width) pt, inspector again")
    }

    /// Bug 1: at 1400 pt, an inspector at its maximum width and then a file pane left the inspector off the edge.
    @Test func openingTheFilePaneBesideAnInspectorAtItsMaximumFits() async throws {
        let fixture = try await fixture(width: 1400)
        defer { fixture.close() }
        await widenInspector(fixture)
        expectPanesFit(fixture, "with the inspector at its maximum")
        await openFilePane(fixture)
        expectPanesFit(fixture, "after opening the file pane")
        await closeFilePane(fixture)
        expectPanesFit(fixture, "after closing the file pane")
    }

    /// Bugs 2 and 3: shrinking with both panes open left the file pane off the edge.
    @Test func shrinkingAndGrowingWithBothPanesOpenFits() async throws {
        let fixture = try await fixture(width: 1400)
        defer { fixture.close() }
        await openFilePane(fixture)
        expectPanesFit(fixture, "at 1400 pt")
        for width in [1300, 1100, 800, 740, 800, 950, 1100, 1300, 1400] as [CGFloat] {
            await resize(width, fixture)
            expectPanesFit(fixture, "after resizing to \(width) pt")
        }
    }

    /// Bug 3: at 740 pt with the sidebar shown the split view ended short of the window's edge.
    @Test(arguments: [true, false])
    func atTheWindowMinimumTheSplitViewReachesTheEdge(inspector: Bool) async throws {
        let fixture = try await fixture(width: 740)
        defer { fixture.close() }
        await setInspector(inspector, fixture)
        expectPanesFit(fixture, "at 740 pt, inspector \(inspector)")
        await openFilePane(fixture)
        expectPanesFit(fixture, "at 740 pt, inspector \(inspector), file pane")
    }

    @Test(arguments: [740, 1000])
    func startingASessionFromTheLaunchFormShowsTheInspector(width: Double) async throws {
        let fixture = try await fixture(width: CGFloat(width))
        defer { fixture.close() }
        fixture.model.showingSetup = true
        await settle(fixture)
        fixture.model.showingSetup = false
        await settle(fixture)
        expectPanesFit(fixture, "after leaving the launch form at \(width) pt")
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

    @Test func theTranscriptYieldsFirstWhenPanesAreWide() {
        // Bug 1: 1160 pt column, 360 pt inspector and the 420 pt file pane leave the transcript 380 pt.
        let panes = DetailPanes(width: 1160, filePane: true, inspector: true)
        let widths = panes.widths(filePane: 420, inspector: 360)
        #expect(widths == .init(transcript: 380, filePane: 420, inspector: 360))
        // A wider file pane than the column allows takes the room the inspector leaves, down to the transcript's minimum.
        let wide = panes.widths(filePane: 2000, inspector: 360)
        #expect(wide == .init(transcript: 240, filePane: 560, inspector: 360))
    }

    @Test func shrinkingTheColumnShrinksTheFilePaneBeforeTheInspector() {
        // Bug 2: the file pane was 350 pt wide in a 740 pt window whose column has 500 pt.
        let narrow = DetailPanes(width: 500, filePane: true, inspector: true)
        #expect(narrow.widths(filePane: 350, inspector: 260) == .init(transcript: 240, filePane: 260, inspector: 0))
        let both = DetailPanes(width: 700, filePane: true, inspector: true)
        #expect(both.widths(filePane: 420, inspector: 260) == .init(transcript: 240, filePane: 240, inspector: 220))
        #expect(both.widths(filePane: 420, inspector: 360) == .init(transcript: 240, filePane: 240, inspector: 220))
    }

    @Test func widthsAlwaysFillTheColumnAndKeepTheMinimums() {
        for width in stride(from: CGFloat(300), through: 2000, by: 37) {
            for file in [false, true] {
                for inspector in [false, true] {
                    let panes = DetailPanes(width: width, filePane: file, inspector: inspector)
                    for preferredFile in [100, 420, 3000] as [CGFloat] {
                        for preferredInspector in [100, 260, 3000] as [CGFloat] {
                            let widths = panes.widths(filePane: preferredFile, inspector: preferredInspector)
                            let context = "\(width) pt, file \(file), inspector \(inspector)"
                            #expect(widths.transcript + widths.filePane + widths.inspector == width, "\(context)")
                            #expect(widths.transcript >= DetailPanes.transcriptMinWidth, "\(context)")
                            #expect(
                                widths.filePane == 0 || widths.filePane >= DetailPanes.filePaneMinWidth,
                                "\(context)"
                            )
                            #expect(
                                widths.inspector == 0
                                    || (DetailPanes.inspectorMinWidth...DetailPanes.inspectorMaxWidth)
                                        .contains(widths.inspector),
                                "\(context)"
                            )
                            #expect(
                                (widths.filePane > 0) == panes.showsFilePane
                                    && (widths.inspector > 0) == panes.showsInspector
                            )
                        }
                    }
                }
            }
        }
    }
}
