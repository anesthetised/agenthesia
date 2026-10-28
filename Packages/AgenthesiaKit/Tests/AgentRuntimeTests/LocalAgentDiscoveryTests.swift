import Foundation
import Testing

@testable import AgentRuntime

@Suite struct LocalAgentDiscoveryTests {
    @Test func findsExecutableFilesOnAbsolutePathEntriesInTableOrderWithoutResolvingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first bin")
        let second = root.appending(path: "second")
        let cellar = root.appending(path: "cellar")
        for directory in [first, second, cellar] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try executable(cellar.appending(path: "opencode"))
        try FileManager.default.createSymbolicLink(
            at: first.appending(path: "opencode"),
            withDestinationURL: cellar.appending(path: "opencode")
        )
        try executable(second.appending(path: "opencode"))
        try executable(second.appending(path: "claude"))
        // Neither a plain file nor a directory is a command.
        try Data().write(to: first.appending(path: "gemini"))
        try FileManager.default.createDirectory(at: first.appending(path: "goose"), withIntermediateDirectories: true)

        let path = ["relative", first.path(percentEncoded: false), second.path(percentEncoded: false)].joined(
            separator: ":"
        )
        let found = LocalAgentDiscovery.discover(path: path)
        #expect(found.map(\.entry.executable) == ["opencode", "claude"])
        #expect(
            found.map(\.path)
                == [first.appending(path: "opencode"), second.appending(path: "claude")].map {
                    $0.path(percentEncoded: false)
                }
        )
        #expect(found.first?.entry.arguments == ["acp"])
        #expect(found.last?.entry.adapterID == "claude-acp")
        #expect(LocalAgentDiscovery.discover(path: nil).isEmpty)
    }

    @Test func tableNamesEachCommandOnceAndAdaptersOnlyForArgumentlessCLIs() {
        let executables = LocalAgentDiscovery.known.map(\.executable)
        #expect(Set(executables).count == executables.count)
        for entry in LocalAgentDiscovery.known where entry.adapterID != nil {
            #expect(entry.arguments.isEmpty)
            #expect(LocalAgentDiscovery.known.contains { $0.registryID == entry.adapterID && $0.adapterID == nil })
        }
    }

    private func executable(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}
