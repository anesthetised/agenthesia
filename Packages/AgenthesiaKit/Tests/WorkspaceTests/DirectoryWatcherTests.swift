import Foundation
import Testing

@testable import Workspace

@MainActor @Suite(.timeLimit(.minutes(1))) struct DirectoryWatcherTests {
    @Test func reportsExternalWritesAndStopsAfterClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watcher-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        let watcher = try DirectoryWatcher(directories: [directory]) { changes += 1 }
        try "external edit".write(to: directory.appending(path: "file"), atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while changes == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes > 0)
        watcher.close()
        watcher.close()
        let closedChanges = changes
        try "after close".write(to: directory.appending(path: "file"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == closedChanges)
    }

    @Test func ignoresExcludedDirectories() async throws {
        let created = FileManager.default.temporaryDirectory.appending(path: "watcher-\(UUID())")
        try FileManager.default.createDirectory(
            at: created.appending(path: "objects"),
            withIntermediateDirectories: true
        )
        let directory = ScopedFileAccess(roots: [created]).roots[0]
        let excluded = directory.appending(path: "objects")
        defer { try? FileManager.default.removeItem(at: created) }
        var changes = 0
        let watcher = try DirectoryWatcher(directories: [directory], excluding: [excluded]) { changes += 1 }
        defer { watcher.close() }
        // FSEvents can still deliver the fixture's own directory creation after the stream starts.
        try await Task.sleep(for: .milliseconds(300))
        changes = 0
        try "object".write(to: excluded.appending(path: "file"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(changes == 0)
        try "ref".write(to: directory.appending(path: "file"), atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while changes == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes > 0)
    }

    @Test func rejectsEmptyOrInvalidRoots() throws {
        for roots in [[], [try #require(URL(string: "https://example.com"))], [URL(filePath: "/tmp/invalid\0root")]] {
            #expect(throws: (any Error).self) { try DirectoryWatcher(directories: roots) {} }
        }
        let root = FileManager.default.temporaryDirectory
        #expect(throws: (any Error).self) {
            try DirectoryWatcher(directories: [root], excluding: Array(repeating: root, count: 9)) {}
        }
        #expect(throws: (any Error).self) {
            try DirectoryWatcher(directories: [root], excluding: [URL(filePath: "/tmp/invalid\0root")]) {}
        }
    }
}
