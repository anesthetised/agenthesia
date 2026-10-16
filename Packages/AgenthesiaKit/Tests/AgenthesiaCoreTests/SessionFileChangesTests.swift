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

    @Test func ignoresGitObjectWritesButNotRefChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-changes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialize = Process()
        initialize.executableURL = URL(filePath: "/usr/bin/git")
        initialize.arguments = ["init", "-q", directory.path]
        initialize.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        try initialize.run()
        initialize.waitUntilExit()
        let git = directory.appending(path: ".git")
        try FileManager.default.createDirectory(
            at: git.appending(path: "objects/aa"),
            withIntermediateDirectories: true
        )
        var invalidations = 0
        let changes = try await SessionFileChanges(directory: directory) { invalidations += 1 }
        defer { changes.close() }
        // FSEvents can still deliver the fixture's own writes after the stream starts.
        try await Task.sleep(for: .milliseconds(300))
        invalidations = 0
        try "object".write(to: git.appending(path: "objects/aa/object"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(invalidations == 0)
        try "ref".write(to: git.appending(path: "refs/heads/probe"), atomically: false, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while invalidations == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(invalidations > 0)
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
