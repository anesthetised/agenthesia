import ACP
import Foundation
import JSONRPC
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor private final class FileSessionFixture {
    let directory: URL
    let root: URL
    let additional: URL
    let controller: SessionController
    let server: Connection
    let client: InMemoryTransport

    init(additionalRoots: Bool = false, additionalPaths: [String]? = nil) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
            .resolvingSymlinksInPath()
        root = directory.appending(path: "root")
        additional = directory.appending(path: "additional")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        let store = try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        let project = ProjectRecord(name: "Test", rootPath: root.path)
        let agent = AgentInstallRecord(name: "Test", executable: "MockAgent")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        controller = SessionController(
            session: .init(projectID: project.id, agentInstallID: agent.id, workingDirectory: root.path),
            store: store,
            additionalDirectories: additionalPaths ?? (additionalRoots ? [additional.path] : [])
        )
        let (serverTransport, clientTransport) = InMemoryTransport.pair()
        server = Connection(transport: serverTransport)
        client = clientTransport
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func start(supportsAdditionalRoots: Bool = true, queue: DispatchQueue? = nil) async throws -> SessionFileSystem {
        var router = Router()
        router.on(ACP.V1.Method.Initialize.self) { request in
            #expect(request.clientCapabilities?.fs?.readTextFile == true)
            #expect(request.clientCapabilities?.fs?.writeTextFile == true)
            return .init(
                protocolVersion: 1,
                agentCapabilities: .init(
                    sessionCapabilities: .init(additionalDirectories: supportsAdditionalRoots ? .init() : nil)
                )
            )
        }
        let roots = controller.additionalDirectories
        router.on(ACP.V1.Method.NewSession.self) { request in
            #expect(request.additionalDirectories ?? [] == roots)
            return .init(sessionId: "s")
        }
        await server.start(handler: router)
        let files = try await SessionFileSystem(controller: controller, queue: queue)
        controller.fileSystem = files
        let connection = await ACP.V1.AgentConnectionAdapter(
            transport: client,
            delegate: controller,
            fileSystem: files
        )
        try await controller.start(connection: connection, client: .init(name: "test", version: "1"))
        return files
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionFileSystemTests {
    @Test func servesWireRequestsWithinBothRootsAndRejectsOtherSessionsAndPaths() async throws {
        let fixture = try await FileSessionFixture(additionalRoots: true)
        _ = try await fixture.start()
        for root in [fixture.root, fixture.additional] {
            let path = root.appending(path: "nested/file.txt").path
            _ = try await fixture.server.request(
                ACP.V1.Method.WriteTextFile.self,
                .init(sessionId: "s", path: path, content: "one\ntwo")
            )
            let response = try await fixture.server.request(
                ACP.V1.Method.ReadTextFile.self,
                .init(sessionId: "s", path: path, line: 2, limit: 1)
            )
            #expect(response.content == "two")
        }
        for (id, path) in [
            ("other", fixture.root.appending(path: "bad.txt").path),
            ("s", fixture.directory.appending(path: "bad.txt").path),
        ] {
            await #expect(throws: RPCError.self) {
                _ = try await fixture.server.request(
                    ACP.V1.Method.WriteTextFile.self,
                    .init(sessionId: id, path: path, content: "bad")
                )
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        await fixture.controller.close()
    }

    @Test func rejectsRequestsBeforeStartAfterFailureAndAfterClose() async throws {
        let fixture = try await FileSessionFixture()
        let unstarted = try await SessionFileSystem(controller: fixture.controller)
        let path = fixture.root.appending(path: "file.txt").path
        await #expect(throws: RPCError.self) {
            try await unstarted.writeTextFile(at: path, content: "bad", in: "s")
        }
        let files = try await fixture.start()
        // This agent has no prompt handler: a failed turn must revoke filesystem access.
        await #expect(throws: (any Error).self) { try await fixture.controller.send([.init(text: "fail")]) }
        #expect(fixture.controller.status == .failed)
        await #expect(throws: RPCError.self) {
            try await files.writeTextFile(at: path, content: "bad", in: "s")
        }
        await fixture.controller.close()
        await #expect(throws: RPCError.self) {
            _ = try await files.readTextFile(at: path, line: nil, limit: nil, in: "s")
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func closeDrainsAcceptedWritesAndRejectsNewOnes() async throws {
        let fixture = try await FileSessionFixture()
        let queue = DispatchQueue(label: "session-files-test")
        let files = try await fixture.start(queue: queue)
        queue.suspend()
        let path = fixture.root.appending(path: "file.txt").path
        let write = Task { try await files.writeTextFile(at: path, content: "accepted", in: "s") }
        while files.pendingOperations == 0 { await Task.yield() }
        var closed = false
        let close = Task {
            await fixture.controller.close(); closed = true
        }
        while fixture.controller.status != .closed { await Task.yield() }
        #expect(!closed)
        await #expect(throws: RPCError.self) {
            try await files.writeTextFile(at: path, content: "late", in: "s")
        }
        queue.resume()
        try await write.value
        await close.value
        #expect(closed)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "accepted")
        await files.close()
    }

    @Test func unsupportedAdditionalDirectoriesFailBeforeCreatingTheRemoteSession() async throws {
        let fixture = try await FileSessionFixture(additionalRoots: true)
        await #expect(throws: SessionController.SessionError.unsupportedAdditionalDirectories) {
            _ = try await fixture.start(supportsAdditionalRoots: false)
        }
        #expect(fixture.controller.session.agentSessionID == nil)
        #expect(fixture.controller.status == .failed)
        await fixture.controller.close()
    }

    @Test(arguments: ["relative", "/dev/null", "/agenthesia-missing-directory", "/tmp/invalid\0root"])
    func rejectsInvalidRoots(path: String) async throws {
        let fixture = try await FileSessionFixture(additionalPaths: [path])
        await #expect(throws: (any Error).self) { _ = try await SessionFileSystem(controller: fixture.controller) }
    }

    @Test func acceptsAnExplicitDirectorySymlinkAsAnAdditionalRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "additional-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target")
        let link = directory.appending(path: "link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fixture = try await FileSessionFixture(additionalPaths: [link.path])
        let files = try await fixture.start()
        try await files.writeTextFile(at: link.appending(path: "file").path, content: "allowed", in: "s")
        #expect(try String(contentsOf: target.appending(path: "file"), encoding: .utf8) == "allowed")
        await fixture.controller.close()
    }

    @Test func returnsUsefulErrorsAndHonorsCancellationBeforeAdmission() async throws {
        let fixture = try await FileSessionFixture()
        let files = try await fixture.start()
        let binary = fixture.root.appending(path: "binary")
        try Data([0xFF]).write(to: binary)
        for path in [
            "relative", binary.path, fixture.root.path, fixture.root.appending(path: "missing").path,
            fixture.root.path + "/invalid\0",
        ] {
            await #expect(throws: RPCError.self) {
                _ = try await files.readTextFile(at: path, line: nil, limit: nil, in: "s")
            }
        }
        let path = fixture.root.appending(path: "cancelled").path
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await files.writeTextFile(at: path, content: "bad", in: "s")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(SessionFileSystem.rpcError(.io(path, 13)).code == RPCError.internalErrorCode)
        await fixture.controller.close()
    }
}
