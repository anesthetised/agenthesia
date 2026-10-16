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

    @Test func rejectsEmptyOrInvalidRoots() throws {
        for roots in [[], [try #require(URL(string: "https://example.com"))], [URL(filePath: "/tmp/invalid\0root")]] {
            #expect(throws: (any Error).self) { try DirectoryWatcher(directories: roots) {} }
        }
    }
}
