import Foundation
import Persistence
import Testing
import Workspace

@testable import AgenthesiaCore

/// Sessions without a project, each in its own folder under the scratch root (ADR-0048).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScratchSessionTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scratch-session-\(UUID())")
        let library: SessionLibrary
        var scratch: URL { directory.appending(path: "scratch") }

        init() {
            library = SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func mock(_ arguments: [String] = []) throws -> AgentInstallRecord {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
        }

        @MainActor func start(_ agent: AgentInstallRecord, text: String = "Plan a trip") async -> LiveSession {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            await owner.start(directory: nil, agent: agent, scratchRoot: scratch, initialPrompt: .init(text: text))
            return owner
        }

        func folders() throws -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.sorted() ?? []
        }
    }

    @Test func runsInItsOwnFolderUnderOneNoProjectProject() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = await fixture.start(try fixture.mock(["--reopen"]))
        let second = await fixture.start(try fixture.mock(["--reopen"]), text: "Write a poem")
        let one = try #require(first.controller?.session)
        let two = try #require(second.controller?.session)
        #expect(one.agentSessionID != nil && two.agentSessionID != nil)
        let prefix = { (id: UUID) in id.uuidString.lowercased().prefix(8) }
        #expect(try fixture.folders() == ["plan-a-trip-\(prefix(one.id))", "write-a-poem-\(prefix(two.id))"].sorted())
        #expect(one.workingDirectory.hasPrefix(SessionWorkspace.scratchProjectPath(fixture.scratch) + "/"))
        #expect(one.baseRevision == nil && one.branch == nil)

        let projects = try await fixture.library.projects()
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.name == "No project")
        #expect(project.isScratch(scratchPath: SessionWorkspace.scratchProjectPath(fixture.scratch)))
        #expect(one.projectID == project.id && two.projectID == project.id)
        await first.close()
        await second.close()
        // A started session keeps its folder.
        #expect(FileManager.default.fileExists(atPath: one.workingDirectory))
    }

    @Test func aFailedStartRemovesItsEmptyFolder() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // The executable exists, so the folder is created, then the agent exits before answering `initialize`.
        let owner = await fixture.start(AgentInstallRecord(name: "Exits", executable: "/usr/bin/false"))
        #expect(owner.errorMessage != nil)
        #expect(try #require(owner.controller).session.agentSessionID == nil)
        #expect(try fixture.folders().isEmpty)
        #expect(owner.workingDirectory == nil)
        #expect(try await fixture.library.history().isEmpty)
        await owner.close()
    }

    @Test func cancellingAtSignInRemovesTheFolder() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let signedOut = try fixture.mock([
            "--auth", "--auth-file", fixture.directory.appending(path: "signed-in").path(percentEncoded: false),
        ])
        let owner = await fixture.start(signedOut)
        #expect(owner.signIn != nil)
        #expect(try fixture.folders().count == 1)
        await owner.close()
        #expect(try fixture.folders().isEmpty)
    }
}
