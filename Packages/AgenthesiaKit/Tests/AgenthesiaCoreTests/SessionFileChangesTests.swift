import Foundation
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionFileChangesTests {
    @Test func bridgesExternalChangesAndReportsNonGitDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-changes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await !SessionFileChanges.isGitRepository(in: directory))
        await #expect(throws: (any Error).self) { try await SessionFileChanges.paths(in: directory, baseRevision: nil) }
        var invalidations = 0
        let changes = try await SessionFileChanges(directory: directory) { invalidations += 1 }
        try "external".write(to: directory.appending(path: "file"), atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while invalidations == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(invalidations > 0)
        changes.close()
    }

    @Test func rejectsBrokenGitAndCancelledWatcherCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-changes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "gitdir: missing".write(to: directory.appending(path: ".git"), atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await SessionFileChanges.isGitRepository(in: directory) }
        await #expect(throws: (any Error).self) { try await SessionFileChanges(directory: directory) {} }
        try FileManager.default.removeItem(at: directory.appending(path: ".git"))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SessionFileChanges(directory: directory) {}
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
