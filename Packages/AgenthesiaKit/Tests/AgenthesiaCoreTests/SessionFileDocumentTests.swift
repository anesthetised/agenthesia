import Foundation
import Testing
import Workspace

@testable import AgenthesiaCore

@Suite struct SessionFileDocumentTests {
    @Test func loadsUTF8AndEmptyFiles() async throws {
        let root = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "sample.swift")
        try "let café = \"👩🏽‍💻\"\n".write(to: file, atomically: true, encoding: .utf8)
        let document = try await SessionFileDocument.load(root: root, url: file)
        #expect(document.text == "let café = \"👩🏽‍💻\"\n")
        #expect(document.url == file)
        try Data().write(to: file)
        #expect(try await SessionFileDocument.load(root: root, url: file).text.isEmpty)
    }

    @Test func rejectsUnsupportedAndOversizedFiles() async throws {
        let root = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "file")
        for bytes in [Data([0xFF]), Data("a\0b".utf8)] {
            try bytes.write(to: file)
            await #expect(throws: SessionFileDocument.Failure.notText) {
                try await SessionFileDocument.load(root: root, url: file)
            }
        }
        try Data(repeating: 0x61, count: SessionFileDocument.maximumBytes).write(to: file)
        #expect(
            try await SessionFileDocument.load(root: root, url: file).text.utf8.count
                == SessionFileDocument.maximumBytes
        )
        try Data(repeating: 0x61, count: SessionFileDocument.maximumBytes + 1).write(to: file)
        await #expect(throws: SessionFileDocument.Failure.tooLarge) {
            try await SessionFileDocument.load(root: root, url: file)
        }
    }

    @Test func rejectsRootReplacedBySymlinkAfterAttachment() async throws {
        let base = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        let root = base.appending(path: "workspace")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appending(path: "file.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await SessionFileDocument.load(root: root, url: file).text == "original")
        try "outside".write(to: outside.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: root, to: base.appending(path: "original"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        await #expect(throws: SessionFileDocument.Failure.outsideScope) {
            try await SessionFileDocument.load(root: root, url: file)
        }
    }

    @Test func rejectsOutsideScopeMissingAndNonFileURLs() async throws {
        let root = ScopedFileAccess(roots: [FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)])
            .roots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: SessionFileDocument.Failure.outsideScope) {
            try await SessionFileDocument.load(
                root: root,
                url: root.deletingLastPathComponent().appending(path: "other")
            )
        }
        await #expect(throws: SessionFileDocument.Failure.notFound) {
            try await SessionFileDocument.load(root: root, url: root.appending(path: "missing"))
        }
        await #expect(throws: SessionFileDocument.Failure.notRegularFile) {
            try await SessionFileDocument.load(root: root, url: root)
        }
        await #expect(throws: SessionFileDocument.Failure.invalidPath) {
            try await SessionFileDocument.load(root: root, url: URL(string: "https://example.com/file")!)
        }
    }
}
