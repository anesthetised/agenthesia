import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct FileIndexTests {
    @Test func gitIncludesTrackedAndUntrackedButNotIgnoredFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await SessionWorkspace.git(["init", "-q"], in: root)
        for path in ["tracked.swift", "untracked.swift", "ignored.log", "space and\nnewline.swift"] {
            try "text".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        }
        try "*.log\ntracked.swift\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try await SessionWorkspace.git(["add", "-f", "tracked.swift"], in: root)
        let index = try await FileIndex.load(in: root)
        #expect(index.paths == [".gitignore", "space and\nnewline.swift", "tracked.swift", "untracked.swift"])
    }

    @Test func selectedSubdirectoryDoesNotIncludeSiblingFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try await SessionWorkspace.git(["init", "-q"], in: root)
        try "text".write(to: root.appending(path: "outside"), atomically: true, encoding: .utf8)
        try "text".write(to: child.appending(path: "inside"), atomically: true, encoding: .utf8)
        #expect(try await FileIndex.load(in: child).paths == ["inside"])
    }

    @Test func directoryWalkKeepsDotfilesAndDoesNotFollowDirectoryLinks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "text".write(to: child.appending(path: ".hidden"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "loop"), withDestinationURL: root)
        let index = try await FileIndex.load(in: root)
        #expect(index.paths == ["nested/.hidden"])
    }

    @Test func fuzzyMatchingPrioritizesBasenamesAndIsBoundedAndDeterministic() throws {
        let index = FileIndex(paths: ["folder/RootView.swift", "rv", "rv-extra", "xrvx", "root/very/file", "Raven"])
        #expect(
            try index.matching("RV") == ["rv", "rv-extra", "xrvx", "Raven", "folder/RootView.swift", "root/very/file"]
        )
        #expect(try index.matching("rv", limit: 2) == ["rv", "rv-extra"])
        #expect(try index.matching("no match").isEmpty)
        #expect(try index.matching("", limit: 2) == ["Raven", "folder/RootView.swift"])
        #expect(try index.matching("rv", limit: 0).isEmpty)
    }

    @Test func cancellationDoesNotReturnResults() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileIndex(paths: ["file"]).matching("file")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelledLoadDoesNotStartFilesystemWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileIndex.load(in: URL(filePath: "/missing-file-index-\(UUID())"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "file-index-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
