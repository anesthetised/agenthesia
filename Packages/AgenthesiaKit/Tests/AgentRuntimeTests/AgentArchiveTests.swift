import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct AgentArchiveTests {
    @Test func readsSystemGeneratedGzipAndZipArchives() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let contents = fixture.root.appending(path: "contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: contents.appending(path: "agent"))
        for kind in ["gzip", "zip"] {
            let archive = fixture.root.appending(path: "system-\(kind)")
            let arguments =
                kind == "gzip"
                ? ["-czf", archive.path, "-C", contents.path, "."]
                : ["--format=zip", "-cf", archive.path, "-C", contents.path, "."]
            #expect(
                await CommandOutput.capture(.init(executable: "/usr/bin/tar", arguments: arguments))
                    == .success(Data(), 0)
            )
            let extracted = fixture.root.appending(path: "extracted-\(kind)")
            try await AgentArchive.extract(archive, to: extracted)
            #expect(try String(contentsOf: extracted.appending(path: "agent"), encoding: .utf8) == "fixture")
        }
    }

    @Test func refusesAnExistingDestinationLink() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let elsewhere = fixture.root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: elsewhere)
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(fixture.archive, to: fixture.destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func extractsFilesAndNormalizesPermissions() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try await AgentArchive.extract(fixture.archive, to: fixture.destination)
        let executable = fixture.destination.appending(path: "bin/agent")
        #expect(try String(contentsOf: executable, encoding: .utf8) == "#!/bin/sh\necho fixture\n")
        let mode = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test(arguments: ["../escaped", "/tmp/escaped", "bin/../../escaped", "bin\\escaped", "bin\nescaped"])
    func refusesUnsafePaths(_ path: String) async throws {
        let fixture = try ArchiveFixture(entries: [(path, "x", "0")])
        defer { fixture.remove() }
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(fixture.archive, to: fixture.destination)
        }
    }

    @Test(arguments: ["1", "2", "3", "6"])
    func refusesLinksAndSpecialFiles(_ type: String) async throws {
        let fixture = try ArchiveFixture(entries: [("agent", "", type)])
        defer { fixture.remove() }
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(fixture.archive, to: fixture.destination)
        }
    }

    @Test func boundsExpansionRejectsDuplicatesAndTruncation() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(fixture.archive, to: fixture.destination, maximumBytes: 3)
        }
        let duplicate = try ArchiveFixture(entries: [("agent", "one", "0"), ("agent", "two", "0")])
        defer { duplicate.remove() }
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(duplicate.archive, to: duplicate.destination)
        }
        let truncated = try ArchiveFixture()
        defer { truncated.remove() }
        // Keep a valid header but cut off the declared file's contents, using a fresh destination.
        try Data(contentsOf: truncated.archive).prefix(515).write(to: truncated.archive)
        await #expect(throws: AgentInstallation.Failure.unsafeArchive) {
            try await AgentArchive.extract(truncated.archive, to: truncated.destination)
        }
    }
}

struct ArchiveFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "agh-install-\(UUID())")
    var archive: URL { root.appending(path: "agent.tar") }
    var destination: URL { root.appending(path: "extracted") }

    init(entries: [(String, String, String)] = [("bin/agent", "#!/bin/sh\necho fixture\n", "0")]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var data = Data()
        for (path, contents, type) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ value: String, at offset: Int) {
                for (i, byte) in value.utf8.enumerated() { header[offset + i] = byte }
            }
            put(path, at: 0)
            put("0004755", at: 100)
            put("0000000", at: 108)
            put("0000000", at: 116)
            put(String(format: "%011o", contents.utf8.count), at: 124)
            put("00000000000", at: 136)
            put("        ", at: 148)
            put(type, at: 156)
            if type == "1" || type == "2" { put("../outside", at: 157) }
            put("ustar", at: 257)
            put("00", at: 263)
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148)
            data.append(contentsOf: header)
            data.append(contentsOf: contents.utf8)
            data.append(Data(repeating: 0, count: (512 - contents.utf8.count % 512) % 512))
        }
        data.append(Data(repeating: 0, count: 1024))
        try data.write(to: archive)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
