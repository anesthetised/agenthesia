import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct SessionWindowModelTests {
    @Test func savedHistoryCanBeSelectedAndClosingPreventsNewLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        let store = try await library.store()
        let project = ProjectRecord(name: "Test", rootPath: directory.path)
        let agent = AgentInstallRecord(name: "Test", executable: "unused")
        let record = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: directory.path)
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(record)
        let model = SessionWindowModel(library: library)
        await model.refresh()
        #expect(model.history == [record])
        await model.showHistory(record)
        #expect(model.displayed?.status == .readOnly)
        #expect(!model.isLoadingHistory)
        model.showLive()
        #expect(model.displayed == nil)
        #expect(model.canStart)
        await model.close()
        #expect(!model.canStart)
        await model.start(directory: directory, executable: "/does-not-exist", arguments: [])
        #expect(model.owner == nil)
    }

    @Test func transcriptTableDoesNotRetainItsSource() {
        let table = TranscriptTableController()
        weak var retained: DemoSession?
        do {
            let source = DemoSession()
            retained = source
            table.update(source)
        }
        #expect(retained == nil)
    }
}
