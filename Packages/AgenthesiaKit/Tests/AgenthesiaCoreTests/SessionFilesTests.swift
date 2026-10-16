import Foundation
import Persistence
import Testing
import Workspace

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SessionFilesTests {
    @Test func rootReplacementDuringScanCannotPublishOutsideFilenames() async throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "scan-root-\(UUID())")
        let root = fixture.appending(path: "root")
        let outside = fixture.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "outside".write(to: outside.appending(path: "outside.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        defer { files.close() }
        files.indexLoader = { captured, _ in
            try FileManager.default.moveItem(at: captured, to: fixture.appending(path: "original"))
            try FileManager.default.createSymbolicLink(at: captured, withDestinationURL: outside)
            return try await FileIndex.load(in: captured)
        }
        var finished = false
        let attaching = Task {
            await files.attach(record(root))
            finished = true
        }
        var publishedOutside = false
        while !finished {
            if files.matches.contains("outside.txt") { publishedOutside = true }
            await Task.yield()
        }
        await attaching.value
        #expect(!publishedOutside)
        #expect(files.matches.isEmpty)
        #expect(files.changedPaths.isEmpty)
        #expect(files.indexError == SessionFileDocument.Failure.outsideScope.localizedDescription)
        #expect(files.changesError == files.indexError)
        #expect(!files.isLoadingIndex)
    }

    private func record(_ root: URL) -> SessionRecord {
        SessionRecord(projectID: UUID(), agentInstallID: UUID(), workingDirectory: root.path)
    }

    @Test func browsesNonGitFoldersAndReportsUnavailableChangeTracking() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        await files.attach(record(root))
        let id = try #require(files.sessionID)
        #expect(files.matches == ["hello.txt"])
        #expect(files.isGitRepository == false)
        await files.open(path: "hello.txt", in: id)
        #expect(files.document?.text == "hello")
        await files.open(path: "../outside.txt", in: id)
        #expect(files.document == nil)
        #expect(files.documentError != nil)
        files.close()
        #expect(files.root == nil)
        #expect(files.selectedPath == nil)
    }

    @Test func replacedSelectionCannotPublishAnOlderRead() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SessionFiles()
        await files.attach(record(root))
        let id = try #require(files.sessionID)
        var continuation: CheckedContinuation<SessionFileDocument, Never>?
        files.documentLoader = { _, url in
            if url.lastPathComponent == "old.txt" {
                return await withCheckedContinuation { continuation = $0 }
            }
            return SessionFileDocument(url: url, text: "new")
        }
        let old = Task { await files.open(path: "old.txt", in: id) }
        while continuation == nil { await Task.yield() }
        await files.open(path: "new.txt", in: id)
        continuation?.resume(returning: SessionFileDocument(url: root.appending(path: "old.txt"), text: "old"))
        await old.value
        #expect(files.selectedPath == "new.txt")
        #expect(files.document?.text == "new")
        files.close()
    }

    @Test func refreshDiscoversGitAndExternalEditsUpdateWorkingChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "note.md")
        try "initial".write(to: file, atomically: true, encoding: .utf8)
        let files = SessionFiles()
        await files.attach(record(root))
        #expect(!files.isGitRepository)
        try await git(["init", "-q"], in: root)
        try await git(["add", "."], in: root)
        try await git(["commit", "-qm", "Initial"], in: root)
        try "edited".write(to: file, atomically: true, encoding: .utf8)
        await files.refresh()
        #expect(files.isGitRepository)
        #expect(files.baseRevision == nil)
        #expect(files.changedPaths == ["note.md"])
        files.setQuery("nm")
        #expect(files.matches.isEmpty)
        #expect(files.isSearching)
        let searchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while files.matches != ["note.md"] && ContinuousClock.now < searchDeadline { await Task.yield() }
        #expect(files.matches == ["note.md"])
        #expect(!files.isSearching)
        try "initial".write(to: file, atomically: true, encoding: .utf8)
        try "new".write(to: root.appending(path: "second.txt"), atomically: true, encoding: .utf8)
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while files.changedPaths != ["second.txt"] && ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(files.changedPaths == ["second.txt"])
        files.close()
    }

    private func git(_ arguments: [String], in directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(filePath: "/usr/bin/git")
                        process.currentDirectoryURL = directory
                        process.arguments =
                            [
                                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c",
                                "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                            ] + arguments
                        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    }
                )
            }
        }
    }

    @Test func backgroundRefreshKeepsVisibleMatchesUntilReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        defer { files.close() }
        await files.attach(record(root))
        files.setQuery("hel")
        while files.isSearching { await Task.yield() }
        #expect(files.matches == ["hello.txt"])
        var continuation: CheckedContinuation<Void, Never>?
        var suspended = false
        files.indexLoader = { root, git in
            // Only the first scan waits; a filesystem event can request another.
            if !suspended {
                suspended = true
                await withCheckedContinuation { continuation = $0 }
            }
            return try await FileIndex.load(in: root, isGitRepository: git)
        }
        try "help".write(to: root.appending(path: "help.txt"), atomically: true, encoding: .utf8)
        let refreshing = Task { await files.refresh() }
        while continuation == nil { await Task.yield() }
        #expect(files.matches == ["hello.txt"])
        continuation?.resume()
        var emptied = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while files.matches != ["help.txt", "hello.txt"] && ContinuousClock.now < deadline {
            if files.matches.isEmpty { emptied = true }
            await Task.yield()
        }
        await refreshing.value
        #expect(!emptied)
        #expect(files.matches == ["help.txt", "hello.txt"])
    }

    @Test func watcherFailureKeepsIndexAndChangesAndIsRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        try await git(["init", "-q"], in: root)
        try await git(["add", "."], in: root)
        try await git(["commit", "-qm", "Initial"], in: root)
        try "edited".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        defer { files.close() }
        var attempts = 0
        files.watcherFactory = { _, _ in
            attempts += 1
            throw CocoaError(.fileReadUnknown)
        }
        await files.attach(record(root))
        #expect(files.matches == ["hello.txt"])
        #expect(files.indexError == nil)
        #expect(files.changedPaths == ["hello.txt"])
        #expect(files.changesError == nil)
        #expect(files.watchError != nil)
        files.watcherFactory = { try await SessionFileChanges(directory: $0, onChange: $1) }
        await files.refresh()
        #expect(attempts == 1)
        #expect(files.watchError == nil)
    }

    @Test func cancelledAttachmentCanAttachTheSameSessionAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        let session = record(root)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await files.attach(session)
        }
        await cancelled.value
        #expect(files.root == nil)
        await files.attach(session)
        #expect(files.matches == ["hello.txt"])
        #expect(!files.isLoadingIndex)
        files.close()
    }

    @Test func obsoleteSessionActionsCannotOpenFilesInTheNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        let old = record(root)
        await files.attach(old)
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "new".write(to: other.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        let current = record(other)
        await files.attach(current)
        await files.open(path: "hello.txt", in: old.id)
        #expect(files.selectedPath == nil)
        #expect(files.document == nil)
        await files.open(path: "hello.txt", in: current.id)
        #expect(files.document?.text == "new")
        files.close()
    }

    @Test func substitutedRootCannotPublishOutsidePathsOrContent() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        let root = base.appending(path: "workspace")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "original".write(to: root.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        let files = SessionFiles()
        let session = record(root)
        await files.attach(session)
        files.setQuery("file")
        try FileManager.default.moveItem(at: root, to: base.appending(path: "original"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        await files.refresh()
        await Task.yield()
        #expect(files.indexError != nil)
        #expect(files.matches.isEmpty)
        #expect(!files.isSearching)
        await files.open(path: "secret.txt", in: session.id)
        #expect(files.document == nil)
        #expect(files.documentError != nil)
        files.close()
    }

    @Test func closingDuringReadDoesNotRestoreDocumentOrLoadingState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SessionFiles()
        await files.attach(record(root))
        let id = try #require(files.sessionID)
        var continuation: CheckedContinuation<SessionFileDocument, Never>?
        files.documentLoader = { _, _ in await withCheckedContinuation { continuation = $0 } }
        let read = Task { await files.open(path: "old.txt", in: id) }
        while continuation == nil { await Task.yield() }
        files.close()
        continuation?.resume(returning: SessionFileDocument(url: root.appending(path: "old.txt"), text: "old"))
        await read.value
        #expect(files.document == nil)
        #expect(!files.isLoadingDocument)
        #expect(files.documentError == nil)
    }

    @Test func cancelledReadCannotLeaveTheLoadingIndicatorActive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "session-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SessionFiles()
        await files.attach(record(root))
        let id = try #require(files.sessionID)
        var continuation: CheckedContinuation<SessionFileDocument, Never>?
        files.documentLoader = { _, _ in await withCheckedContinuation { continuation = $0 } }
        let read = Task { await files.open(path: "old.txt", in: id) }
        while continuation == nil { await Task.yield() }
        read.cancel()
        continuation?.resume(returning: SessionFileDocument(url: root.appending(path: "old.txt"), text: "old"))
        await read.value
        #expect(files.document == nil)
        #expect(!files.isLoadingDocument)
        files.close()
    }
}
