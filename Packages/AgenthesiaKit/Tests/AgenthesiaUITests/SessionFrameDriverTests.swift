import AgenthesiaCore
import AppKit
import Foundation
import Persistence
import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct SessionFrameDriverTests {
    @Test func restartingAndStoppingDoesNotRetainTheSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "frame-driver-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await Task.detached {
            try PersistenceStore(databaseURL: directory.appending(path: "history.sqlite"))
        }.value
        var session: SessionController? = SessionController(
            session: .init(projectID: UUID(), agentInstallID: UUID(), workingDirectory: "/tmp"),
            store: store
        )
        weak let retained = session
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let driver = SessionFrameDriver()
        driver.start(session: try #require(session), in: view)
        driver.start(session: try #require(session), in: view)
        session = nil
        #expect(retained == nil)
        driver.stop()
        driver.stop()
    }
}
