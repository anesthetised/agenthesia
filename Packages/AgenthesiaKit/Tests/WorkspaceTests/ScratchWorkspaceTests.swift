import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct ScratchWorkspaceTests {
    let id = UUID(uuidString: "BAAEEDD5-1234-4321-ABCD-0123456789AB") ?? UUID()

    @Test func createsAnEmptyFolderNamedAfterTheTopic() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-test-\(UUID())/scratch")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let workspace = try await SessionWorkspace.prepareScratch(id: id, topic: "Plan a trip", scratchRoot: root)

        let canonicalRoot = SessionWorkspace.scratchProjectPath(root)
        #expect(workspace.projectDirectory.path == canonicalRoot)
        #expect(workspace.workingDirectory.path == canonicalRoot + "/plan-a-trip-baaeedd5")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.workingDirectory.path).isEmpty)
        #expect(workspace.baseRevision == nil && workspace.baseBranch == nil && workspace.branch == nil)
        #expect(ScopedFileAccess.isCanonical(workspace.workingDirectory))
    }

    @Test func anExistingFolderFailsAndIsLeftAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appending(path: "session-baaeedd5")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appending(path: "note.txt"))

        await #expect(throws: (any Error).self) {
            try await SessionWorkspace.prepareScratch(id: id, scratchRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: existing.appending(path: "note.txt").path))
    }

    @Test func fileAccessReachesOnlyTheSessionFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try await SessionWorkspace.prepareScratch(id: UUID(), topic: "Other", scratchRoot: root)
        try Data("secret".utf8).write(to: other.workingDirectory.appending(path: "secret.txt"))
        let workspace = try await SessionWorkspace.prepareScratch(id: id, topic: "Mine", scratchRoot: root)
        let access = ScopedFileAccess(roots: [workspace.workingDirectory])

        try access.writeText("hello", to: workspace.workingDirectory.appending(path: "a.txt").path)
        #expect(try access.readText(at: workspace.workingDirectory.appending(path: "a.txt").path) == "hello")
        #expect(throws: ScopedFileAccess.Failure.self) {
            try access.readText(at: other.workingDirectory.appending(path: "secret.txt").path)
        }
        #expect(throws: ScopedFileAccess.Failure.self) {
            try access.writeText("x", to: workspace.projectDirectory.appending(path: "b.txt").path)
        }
    }

    @Test func removesOnlyAnEmptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try await SessionWorkspace.prepareScratch(id: id, scratchRoot: root)
        let used = try await SessionWorkspace.prepareScratch(id: UUID(), scratchRoot: root)
        try Data("work".utf8).write(to: used.workingDirectory.appending(path: "work.txt"))

        #expect(try await SessionWorkspace.removeEmptyScratch(empty.workingDirectory))
        #expect(!(try await SessionWorkspace.removeEmptyScratch(used.workingDirectory)))
        #expect(!FileManager.default.fileExists(atPath: empty.workingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: used.workingDirectory.path))
    }
}
