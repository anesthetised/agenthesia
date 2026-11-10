import ACP
import AppKit
import Foundation
import SwiftUI
import TestSupport
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The pending permission docked above the composer (ADR-0039, amendment 2026-11-02).
@MainActor @Suite(.timeLimit(.minutes(1))) struct PermissionDockTests {
    private let options: [ACP.PermissionOption] = [
        .init(optionId: "allow", name: "Allow once", kind: .allowOnce),
        .init(optionId: "always", name: "Always allow", kind: .allowAlways),
        .init(optionId: "reject", name: "Reject", kind: .rejectOnce),
    ]

    private func request(_ call: ACP.ToolCall) -> SessionController.PendingPermission {
        .init(id: UUID(), options: options, toolTitle: call.title, callTitle: call.title, toolCall: call)
    }

    @Test func theCardShowsTheOldestRequestAndCountsThePendingOnes() throws {
        let edit = ACP.ToolCall(
            toolCallId: "edit",
            title: "Update the notes",
            kind: .edit,
            content: [
                .diff(.init(path: "a.txt", oldText: "old", newText: "new")),
                .content(.init(content: .init(text: "Context"))),
                .diff(.init(path: "b.txt", oldText: nil, newText: "b")),
            ],
            locations: [.init(path: "a.txt", line: 1), .init(path: "a.txt", line: 9)]
        )
        let first = request(edit)
        let one = try #require(DockedPermission([first]))
        #expect(one.id == first.id && one.options == options)
        #expect(one.counter == nil)
        #expect(one.operation == "Edit · a.txt, b.txt")
        #expect(one.symbol == "pencil")
        #expect(one.title == "Update the notes")
        #expect(one.diffs.map(\.path) == ["a.txt", "b.txt"])
        #expect(one.announcement == "Permission request: Edit · a.txt, b.txt")

        let command = request(.init(toolCallId: "run", title: "", kind: .execute))
        let several = try #require(DockedPermission([command, first, request(edit)]))
        #expect(several.id == command.id)
        #expect(several.counter == "1 of 3")
        #expect(several.operation == "Execute" && several.title == nil && several.diffs.isEmpty)
        #expect(several.announcement == "Permission request: Execute, 3 pending")
        #expect(DockedPermission([]) == nil)
    }

    @Test func shortcutsNumberTheFirstNineOptions() {
        #expect(DockedPermission.shortcut(at: 0)?.label == "⌥⌘1")
        #expect(DockedPermission.shortcut(at: 0)?.key == KeyboardShortcut("1", modifiers: [.command, .option]))
        #expect(DockedPermission.shortcut(at: 8)?.label == "⌥⌘9")
        #expect(DockedPermission.shortcut(at: 9) == nil)
        #expect(DockedPermission.shortcut(at: -1) == nil)
    }

    @Test func armingIgnoresInputForTheFirst400Milliseconds() {
        let shown = ContinuousClock.now
        let arming = PermissionArming(shownAt: shown)
        #expect(arming.armedAt == shown.advanced(by: .milliseconds(400)))
        #expect(!arming.accepts(at: shown))
        #expect(!arming.accepts(at: shown.advanced(by: .milliseconds(399))))
        #expect(arming.accepts(at: shown.advanced(by: .milliseconds(400))))
    }

    @Test func buttonsWrapInsteadOfNarrowing() {
        let sizes = [CGSize(width: 100, height: 20), CGSize(width: 120, height: 24), CGSize(width: 80, height: 20)]
        let wide = WrappingLayout.origins(of: sizes, width: 400, spacing: 8)
        #expect(wide.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 108, y: 0), CGPoint(x: 236, y: 0)])
        #expect(wide.size == CGSize(width: 316, height: 24))
        let narrow = WrappingLayout.origins(of: sizes, width: 230, spacing: 8)
        #expect(narrow.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 108, y: 0), CGPoint(x: 0, y: 32)])
        #expect(narrow.size == CGSize(width: 228, height: 52))
        // A button wider than the row keeps its width on a row of its own.
        let tight = WrappingLayout.origins(of: sizes, width: 90, spacing: 8)
        #expect(tight.origins.map(\.y) == [0, 28, 60])
        #expect(tight.size.width == 120)
    }

    @Test func answersGoToTheOldestRequestOnlyOnceArmed() async throws {
        let fixture = try await Fixture()
        let controller = fixture.controller
        try await controller.submit([.init(text: "writes 3 hello")])
        try await waitUntil { controller.pendingPermissions.count == 3 }
        let pending = controller.pendingPermissions
        let docked = try #require(DockedPermission(pending))
        #expect(docked.counter == "1 of 3")
        #expect(docked.operation.hasPrefix("Edit · note"))
        #expect(docked.diffs.count == 1 && docked.diffs.first?.oldText == nil)

        let shown = ContinuousClock.now
        let arming = PermissionArming(shownAt: shown)
        #expect(!docked.answer(option: 0, in: controller, arming: arming, at: shown.advanced(by: .milliseconds(399))))
        #expect(controller.pendingPermissions == pending)
        #expect(!docked.answer(option: 5, in: controller, arming: arming, at: arming.armedAt))
        #expect(docked.answer(option: 0, in: controller, arming: arming, at: arming.armedAt))
        #expect(controller.pendingPermissions.map(\.id) == pending.dropFirst().map(\.id))
        // A repeated answer, from a double click or a held shortcut, reaches only the request it was meant for.
        #expect(!docked.answer(option: 0, in: controller, arming: arming, at: arming.armedAt))

        let next = try #require(DockedPermission(controller.pendingPermissions))
        #expect(next.id == pending[1].id && next.counter == "1 of 2")
        for request in controller.pendingPermissions {
            #expect(controller.answerPermission(request.id, with: "reject"))
        }
        try await waitUntil { controller.status == .idle }
        await fixture.remove()
    }

    /// The card shrinks the transcript's clip view; a reader following the end keeps the last lines in view, and the
    /// composer keeps focus while it appears and goes.
    @Test func theTranscriptKeepsFollowingTheEndAndTheComposerKeepsFocus() async throws {
        let fixture = try await Fixture()
        let controller = fixture.controller
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: fixture.model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }

        try await controller.submit([.init(text: String(repeating: "A line to read.\n\n", count: 40))])
        try await waitUntil { controller.status == .idle }
        let scroll = try #require(first(TranscriptScrollView.self, in: view))
        let composer = try #require(first(FileTextView.self, in: view))
        #expect(window.makeFirstResponder(composer))
        func followsEnd() -> Bool {
            guard let table = scroll.documentView, table.frame.height > scroll.contentView.bounds.height else {
                return false
            }
            return abs(scroll.contentView.bounds.maxY - table.frame.height) < 1
        }
        try await waitUntil(followsEnd)
        let height = scroll.contentView.bounds.height

        try await controller.submit([.init(text: "writes 2 hello")])
        try await waitUntil { controller.pendingPermissions.count == 2 && scroll.contentView.bounds.height < height }
        try await waitUntil(followsEnd)
        #expect(window.firstResponder === composer)
        // A one-line diff makes a short card: it hugs its content instead of taking the whole 40 % bound.
        try await waitUntil { height - scroll.contentView.bounds.height < 0.3 * 700 }

        for request in controller.pendingPermissions {
            #expect(controller.answerPermission(request.id, with: "allow"))
        }
        // The card is gone; the baseline may have been taken while the working line still showed, so it is a floor.
        try await waitUntil { controller.status == .idle && scroll.contentView.bounds.height >= height }
        try await waitUntil(followsEnd)
        #expect(window.firstResponder === composer)
        await fixture.remove()
    }

    // MARK: - Support

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "permission-dock-\(UUID())")
        let sessions: SessionManager
        let model: SessionWindowModel
        let controller: SessionController

        init() async throws {
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = SessionWindowModel(sessions: sessions)
            model.start(directory: directory, executable: binary.path, arguments: [])
            let owner = try #require(model.owner)
            await owner.startup?.value
            controller = try #require(owner.controller)
        }

        func remove() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        return view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }
}
