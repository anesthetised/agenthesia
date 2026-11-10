import ACP
import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionMenuBarTests {
    private func fixture() throws -> (URL, SessionManager, AgentInstallRecord) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "menu-bar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        )
        manager.environment = { (ProcessInfo.processInfo.environment, nil) }
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return (directory, manager, AgentInstallRecord(name: "Mock", executable: binary.path))
    }

    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func anEmptyMenuListsNothing() {
        let menu = SessionMenu(owners: [])
        #expect(menu.needsYou.isEmpty && menu.working.isEmpty)
    }

    @Test func aPermissionRequestIsANeedsYouEntryWithTheTitleAndReasonAndAnswersFromTheMenu() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }
        let call = ACP.ToolCallUpdate(toolCallId: "run", title: "swift test", kind: .execute)
        let agentID = try #require(controller.session.agentSessionID)
        let options: [ACP.PermissionOption] = [
            .init(optionId: "allow", name: "Allow once", kind: .allowOnce),
            .init(optionId: "no", name: "Reject", kind: .rejectOnce),
        ]
        let answer = Task { await controller.requestPermission(for: call, options: options, in: agentID) }
        await eventually { !controller.pendingPermissions.isEmpty }

        let menu = SessionMenu(owners: manager.owners)
        #expect(menu.working.isEmpty)
        let entry = try #require(menu.needsYou.first)
        #expect(menu.needsYou.count == 1)
        #expect(entry.text == "\(controller.session.title ?? "New Session") · \(owner.reason ?? "")")
        #expect(entry.text.hasSuffix("· Allow? swift test"))
        #expect(entry.request?.id == controller.pendingPermissions.first?.id)
        #expect(entry.sessionID == controller.session.id)
        #expect(entry.url == WindowTarget.session(controller.session.id).url)
        #expect(
            entry.request.map { PermissionChoice.choices(for: $0, openAlways: true) } == [
                .open, .option(options[0]), .option(options[1]),
            ]
        )

        entry.answer("no")
        #expect(await answer.value == .selected("no"))
        // Answered, the request is gone and a second answer from a stale menu does nothing.
        entry.answer("allow")
        await owner.stop()
        await turn.value
        await manager.closeAll()
    }

    @Test func anEntryAnswersTheRequestItListedNotTheOneThatIsFirstNow() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }
        let agentID = try #require(controller.session.agentSessionID)
        let options: [ACP.PermissionOption] = [
            .init(optionId: "allow", name: "Allow once", kind: .allowOnce),
            .init(optionId: "no", name: "Reject", kind: .rejectOnce),
        ]
        let firstCall = ACP.ToolCallUpdate(toolCallId: "first", title: "swift build", kind: .execute)
        let first = Task { await controller.requestPermission(for: firstCall, options: options, in: agentID) }
        await eventually { controller.pendingPermissions.count == 1 }
        let firstID = try #require(controller.pendingPermissions.first?.id)
        let secondCall = ACP.ToolCallUpdate(toolCallId: "second", title: "swift test", kind: .execute)
        let second = Task { await controller.requestPermission(for: secondCall, options: options, in: agentID) }
        await eventually { controller.pendingPermissions.count == 2 }

        // The menu lists the first request; it is answered elsewhere while the menu is open.
        let entry = try #require(SessionMenu(owners: manager.owners).needsYou.first)
        #expect(entry.request?.id == firstID)
        #expect(controller.answerPermission(firstID, with: "no"))
        #expect(await first.value == .selected("no"))
        let remaining = try #require(controller.pendingPermissions.first)
        #expect(remaining.id != firstID)

        // The click on the gone request does nothing: the second one is still pending.
        entry.answer("allow")
        #expect(controller.pendingPermissions.map(\.id) == [remaining.id])

        await owner.stop()
        _ = await second.value
        await turn.value
        await manager.closeAll()
    }

    @Test func aRunningTurnIsAWorkingEntryWithItsShelfTime() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running && controller.turnStartedAt != nil }
        let started = try #require(controller.turnStartedAt)

        let menu = SessionMenu(owners: manager.owners, now: started.addingTimeInterval(72))
        #expect(menu.needsYou.isEmpty)
        let entry = try #require(menu.working.first)
        #expect(entry.text == "\(controller.session.title ?? "New Session") · Working 1m 12s")
        #expect(entry.request == nil)
        #expect(entry.url == WindowTarget.session(controller.session.id).url)

        await owner.stop()
        await turn.value
        await manager.closeAll()
    }

    @Test func theWorkingEntryNamesThePlanStepInsteadOfTheTime() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        await owner.send("plan")
        await eventually { controller.transcript.plan != nil }
        owner.markSeen()
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }

        let entry = try #require(SessionMenu(owners: manager.owners).working.first)
        #expect(entry.text.hasSuffix(" · Echo it back"))

        await owner.stop()
        await turn.value
        await manager.closeAll()
    }

    @Test func aFailedStartIsNeededAndHasNoRequest() async throws {
        let (directory, manager, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = manager.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Gone", executable: "/nonexistent")
        )
        await owner.startup?.value
        let menu = SessionMenu(owners: manager.owners)
        let entry = try #require(menu.needsYou.first)
        #expect(entry.text.hasSuffix(" · Failed"))
        #expect(entry.request == nil)
        await manager.closeAll()
    }

    /// Hosts `view` in an offscreen window and lets it settle; hosted SwiftUI exposes no accessibility tree to a test
    /// without an assistive client, so the tests below read what the view measures.
    private func host<V: View>(_ view: V, in window: OffscreenWindow) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        return host
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    }

    @Test func theContentViewGrowsWithTheSessionsItLists() async throws {
        _ = NSApplication.shared
        let (directory, manager, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = OffscreenWindow(size: .init(width: 400, height: 300))
        defer { window.close() }
        let host = host(SessionMenuBarContent(sessions: manager), in: window)
        await settle(host)
        let empty = host.fittingSize.height
        #expect(empty > 0)

        let owner = manager.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Gone", executable: "/nonexistent")
        )
        await owner.startup?.value
        await settle(host)
        // A Needs You section: its header and the failed session.
        #expect(host.fittingSize.height > empty)
        await manager.closeAll()
    }

    @Test func theLabelShowsTheNeedsYouCountOnlyWhileItIsAboveZero() async throws {
        _ = NSApplication.shared
        let (directory, manager, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = OffscreenWindow(size: .init(width: 400, height: 300))
        defer { window.close() }
        let host = host(SessionMenuBarLabel(sessions: manager), in: window)
        await settle(host)
        let bare = host.fittingSize.width
        #expect(bare > 0)

        let owner = manager.start(
            directory: directory,
            agent: AgentInstallRecord(name: "Gone", executable: "/nonexistent")
        )
        await owner.startup?.value
        await settle(host)
        #expect(host.fittingSize.width > bare)
        await manager.closeAll()
    }

    @Test func presenceFollowsTheWindowCount() {
        var windows = 0
        let presence = WindowPresence(count: { windows })
        #expect(!presence.isOpen)
        windows = 2
        presence.refresh()
        #expect(presence.isOpen)
        windows = 0
        presence.refresh()
        #expect(!presence.isOpen)
    }
}
