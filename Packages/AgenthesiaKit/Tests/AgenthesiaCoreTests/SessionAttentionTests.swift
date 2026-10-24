import ACP
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor private final class RecordingSink: AttentionSink {
    private(set) var live: [String: AttentionNotice] = [:]
    private(set) var posts: [AttentionNotice] = []
    private(set) var badge = 0
    private(set) var authorizations = 0

    /// While set, `requestAuthorization` waits, as it does while the system prompt is open.
    var holdAuthorization = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func requestAuthorization() async {
        authorizations += 1
        if holdAuthorization { await withCheckedContinuation { held.append($0) } }
    }
    func answerPrompt() {
        holdAuthorization = false
        held.forEach { $0.resume() }
        held = []
    }
    func post(_ notice: AttentionNotice) {
        posts.append(notice)
        live[notice.id] = notice
    }
    func remove(ids: [String]) { for id in ids { live[id] = nil } }
    func setBadge(_ count: Int) { badge = count }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionAttentionTests {
    private func fixture() throws -> (URL, SessionManager, AgentInstallRecord) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-attention-\(UUID())")
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
            await Task.yield()
        }
    }

    private func option(_ id: String, _ kind: ACP.PermissionOptionKind) -> ACP.PermissionOption {
        .init(optionId: id, name: id, kind: kind)
    }

    @Test func actionsNeedBothAllowOnceAndRejectOnce() {
        let allow = option("a", .allowOnce)
        let reject = option("r", .rejectOnce)
        #expect(AttentionNotice.canDecide([allow, reject, option("x", .allowAlways)]))
        #expect(!AttentionNotice.canDecide([allow]))
        #expect(!AttentionNotice.canDecide([reject, option("x", .rejectAlways)]))
        #expect(!AttentionNotice.canDecide([option("a", .allowAlways), option("r", .rejectAlways)]))
        #expect(!AttentionNotice.canDecide([]))
    }

    @Test func aPermissionRequestPostsOnceAndAnsweringItRemovesTheNotice() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write /tmp/attention.txt content") }
        await eventually { !controller.pendingPermissions.isEmpty }
        await eventually { sink.badge == 1 }
        let request = try #require(controller.pendingPermissions.first)
        let notice = try #require(sink.live.values.first)
        #expect(sink.posts.count == 1)
        #expect(notice.kind == .permission(requestID: request.id, canDecide: true))
        #expect(notice.sessionID == controller.session.id)
        #expect(notice.body == "Permission needed")

        #expect(!attention.decide(requestID: UUID(), in: controller.session.id, allow: true))
        #expect(!attention.decide(requestID: request.id, in: UUID(), allow: true))
        #expect(attention.decide(requestID: request.id, in: controller.session.id, allow: false))
        #expect(!attention.decide(requestID: request.id, in: controller.session.id, allow: true))
        await turn.value
        await eventually { sink.badge == 0 && !sink.live.keys.contains(notice.id) }
        #expect(controller.transcript.items.compactMap(\.permission).first?.outcome == .selected("reject"))
        await manager.closeAll()
    }

    @Test func theNoticeNamesTheToolAndKeepsOnlyOfferedActions() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let agentID = try #require(controller.session.agentSessionID)
        let turn = Task { await owner.send("slow") }
        await eventually { controller.status == .running }
        let answer = Task {
            await controller.requestPermission(
                for: .init(toolCallId: "t", title: "Run swift test"),
                options: [option("always", .allowAlways), option("no", .rejectOnce)],
                in: agentID
            )
        }
        await eventually { !sink.live.isEmpty }
        let request = try #require(controller.pendingPermissions.first)
        let notice = try #require(sink.live.values.first)
        #expect(notice.body == "Permission needed: Run swift test")
        #expect(notice.kind == .permission(requestID: request.id, canDecide: false))
        // Without both once-only options the notification only opens the session, and so does `decide`.
        #expect(!attention.decide(requestID: request.id, in: controller.session.id, allow: true))
        #expect(attention.decide(requestID: request.id, in: controller.session.id, allow: false))
        #expect(await answer.value == .selected("no"))
        await owner.stop()
        await turn.value
        await manager.closeAll()
    }

    @Test func allowOnceSelectsTheAllowOption() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attention = SessionAttention(sessions: manager, sink: RecordingSink())
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write /tmp/attention.txt content") }
        await eventually { !controller.pendingPermissions.isEmpty }
        let request = try #require(controller.pendingPermissions.first)
        #expect(attention.decide(requestID: request.id, in: controller.session.id, allow: true))
        await turn.value
        #expect(controller.transcript.items.compactMap(\.permission).first?.outcome == .selected("allow"))
        await manager.closeAll()
    }

    @Test func aSessionShownInTheKeyWindowIsNotNotifiedAndLeavingItNotifies() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let window = NSObject()
        manager.setShown(controller.session.id, in: window)
        let turn = Task { await owner.send("write /tmp/attention.txt content") }
        await eventually { !controller.pendingPermissions.isEmpty }
        // The badge counts what waits whether or not it is in front.
        await eventually { sink.badge == 1 }
        #expect(sink.live.isEmpty)

        manager.setShown(nil, in: window)
        await eventually { sink.live.count == 1 }
        manager.setShown(controller.session.id, in: window)
        await eventually { sink.live.isEmpty }
        manager.setShown(nil, in: window)
        await eventually { sink.live.count == 1 }
        #expect(sink.posts.count == 2)

        let request = try #require(controller.pendingPermissions.first)
        controller.answerPermission(request.id, with: "allow")
        await turn.value
        await manager.closeAll()
    }

    @Test func aFinishedTurnNotifiesUntilItIsSeen() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        await owner.send("hello")
        await eventually { sink.live.count == 1 }
        let notice = try #require(sink.live.values.first)
        #expect(notice.kind == .finished)
        #expect(notice.body == "The agent finished its turn")
        #expect(sink.badge == 0)

        owner.markSeen()
        await eventually { sink.live.isEmpty }
        await owner.send("again")
        await eventually { sink.live.count == 1 }
        #expect(sink.live.values.first?.id != notice.id)
        await manager.closeAll()
    }

    @Test func aFailedSessionNotifiesWithItsError() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        await owner.send("exit")
        await eventually { sink.live.values.contains { $0.kind == .failure } }
        let notice = try #require(sink.live.values.first { $0.kind == .failure })
        #expect(!notice.body.isEmpty)
        await manager.end(owner)
        await eventually { sink.live.isEmpty }
    }

    @Test func aFormRequestPostsAndCountsTowardTheBadge() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let request = ACP.ElicitationRequest(
            message: "Choose a name",
            mode: .form(.init(properties: ["name": .string(.init())])),
            scope: .session(try #require(controller.session.agentSessionID), toolCallId: nil)
        )
        let answer = Task { await controller.requestInput(request) }
        await eventually { !controller.pendingInputs.isEmpty }
        let pending = try #require(controller.pendingInputs.first)
        await eventually { sink.badge == 1 }
        let notice = try #require(sink.live.values.first)
        #expect(notice.kind == .input(requestID: pending.id))
        #expect(notice.body == "Choose a name")

        controller.answerInput(pending.id, with: .init(action: .decline))
        _ = await answer.value
        await eventually { sink.badge == 0 && !sink.live.keys.contains(notice.id) }
        await manager.closeAll()
    }

    @Test func authorizationIsRequestedOnceWhenTheFirstSessionStarts() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        await Task.yield()
        #expect(sink.authorizations == 0)
        let first = manager.start(directory: directory, agent: agent)
        await eventually { sink.authorizations == 1 }
        let second = manager.start(directory: directory, agent: agent)
        await first.startup?.value
        await second.startup?.value
        await Task.yield()
        #expect(sink.authorizations == 1)
        await manager.closeAll()
    }

    @Test func nothingIsPostedBeforeTheSystemHasAnswered() async throws {
        let (directory, manager, agent) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        sink.holdAuthorization = true
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let owner = manager.start(directory: directory, agent: agent)
        await owner.startup?.value
        let controller = try #require(owner.controller)
        let turn = Task { await owner.send("write /tmp/attention.txt content") }
        await eventually { !controller.pendingPermissions.isEmpty }
        await eventually { sink.badge == 1 }
        #expect(sink.authorizations == 1 && sink.posts.isEmpty)

        sink.answerPrompt()
        await eventually { sink.live.count == 1 }
        #expect(sink.posts.count == 1)
        let request = try #require(controller.pendingPermissions.first)
        controller.answerPermission(request.id, with: "allow")
        await turn.value
        await manager.closeAll()
    }

    private func failedResume(_ directory: URL, _ manager: SessionManager) async throws -> (LiveSession, SessionRecord)
    {
        let store = try await manager.library.store()
        let project = ProjectRecord(name: "Test", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Missing", executable: "/does-not-exist")
        let record = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "saved",
            workingDirectory: directory.path
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)
        let owner = manager.resume(record)
        await owner.startup?.value
        return (owner, record)
    }

    @Test func aStartupThatFailedBeforeHavingAControllerStillNotifies() async throws {
        let (directory, manager, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let (owner, record) = try await failedResume(directory, manager)
        #expect(owner.controller == nil && owner.activity == .failed)
        await eventually { sink.live.count == 1 }
        let notice = try #require(sink.live.values.first)
        #expect(notice.kind == .failure && notice.sessionID == record.id)
        #expect(notice.body.contains("/does-not-exist"))

        await manager.end(owner)
        await eventually { sink.live.isEmpty }
    }

    @Test func aFailureSeenInTheWindowIsNotAnnouncedAgainWhenTheUserLeaves() async throws {
        let (directory, manager, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingSink()
        let attention = SessionAttention(sessions: manager, sink: sink)
        defer { withExtendedLifetime(attention) {} }
        let (owner, record) = try await failedResume(directory, manager)
        await eventually { sink.live.count == 1 }

        let window = NSObject()
        manager.setShown(record.id, in: window)
        await eventually { sink.live.isEmpty }
        manager.setShown(nil, in: window)
        for _ in 0..<20 { await Task.yield() }
        #expect(sink.live.isEmpty && sink.posts.count == 1)
        await manager.end(owner)
    }
}
