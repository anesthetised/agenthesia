import Darwin
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore

@Suite(.timeLimit(.minutes(1))) struct MCPSocketTests {
    /// Answers every line with `<session> <line>`.
    private let echo: MCPSocket.Serve = { session, transport in
        do {
            for try await line in transport.messages { try await transport.send(Data("\(session) ".utf8) + line) }
        } catch {}
    }

    @Test func relaysBothWaysAndExitsWhenTheAgentCloses() async throws {
        let tokens = MCPTokens()
        let session = UUID()
        let socket = try MCPSocket(path: Self.testPath(), tokens: tokens, serve: echo)
        defer { socket.close() }
        let helper = try Helper(socket: socket.path, token: tokens.issue(for: session))
        try helper.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(try await helper.line() == #"\#(session) {"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try helper.closeInput()
        #expect(await helper.status() == 0)
    }

    @Test func exitsWhenTheAppCloses() async throws {
        let tokens = MCPTokens()
        let socket = try MCPSocket(path: Self.testPath(), tokens: tokens) { _, transport in
            try? await transport.send(Data("bye".utf8))
        }
        defer { socket.close() }
        let helper = try Helper(socket: socket.path, token: tokens.issue(for: UUID()))
        #expect(try await helper.line() == "bye")
        #expect(try await helper.line() == nil)
        #expect(await helper.status() == 0)
    }

    @Test func closesAConnectionWithAnUnknownOrRevokedToken() async throws {
        let tokens = MCPTokens()
        let session = UUID()
        let revoked = tokens.issue(for: session)
        tokens.revoke(session)
        try await confirmation(expectedCount: 0) { served in
            let socket = try MCPSocket(path: Self.testPath(), tokens: tokens) { _, _ in served() }
            defer { socket.close() }
            for token in ["bad", revoked] {
                let helper = try Helper(socket: socket.path, token: token)
                #expect(try await helper.line() == nil)
                #expect(await helper.status() == 0)
            }
        }
    }

    @Test func servesTwoSessionsOnOneSocket() async throws {
        let tokens = MCPTokens()
        let (first, second) = (UUID(), UUID())
        let socket = try MCPSocket(path: Self.testPath(), tokens: tokens, serve: echo)
        defer { socket.close() }
        let helpers = try [first, second].map { try Helper(socket: socket.path, token: tokens.issue(for: $0)) }
        for helper in helpers { try helper.send("hi") }
        #expect(try await helpers[0].line() == "\(first) hi")
        #expect(try await helpers[1].line() == "\(second) hi")
        for helper in helpers { try helper.closeInput() }
    }

    @Test func pathIsShortPerDataFolderAndPrivate() throws {
        let long = URL(filePath: "/" + String(repeating: "folder/", count: 60))
        let path = MCPSocket.path(dataFolder: long)
        #expect(path.utf8.count < 104)
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
        #expect(path == MCPSocket.path(dataFolder: long))
        #expect(path != MCPSocket.path(dataFolder: long.appending(path: "Agenthesia-dev")))

        let socket = try MCPSocket(path: Self.testPath(), tokens: MCPTokens()) { _, _ in }
        var info = stat()
        #expect(stat(socket.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        socket.close()
        try waitUntil { !FileManager.default.fileExists(atPath: socket.path) }
    }

    @Test func replacesAStaleSocket() async throws {
        let path = Self.testPath()
        // A socket file left behind by an instance that did not close it.
        let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        Darwin.close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let tokens = MCPTokens()
        let session = UUID()
        let socket = try MCPSocket(path: path, tokens: tokens, serve: echo)
        defer { socket.close() }
        let helper = try Helper(socket: path, token: tokens.issue(for: session))
        try helper.send("hi")
        #expect(try await helper.line() == "\(session) hi")
        try helper.closeInput()
    }

    @Test func rejectsAPathLongerThanSunPath() {
        #expect(throws: POSIXError(.ENAMETOOLONG)) {
            try MCPSocket(path: "/tmp/" + String(repeating: "x", count: 104), tokens: MCPTokens()) { _, _ in }
        }
    }

    @Test func tokensAre256RandomBits() {
        let tokens = MCPTokens()
        let session = UUID()
        let (a, b) = (tokens.issue(for: session), tokens.issue(for: session))
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit))
        #expect(a != b)
        #expect(tokens.session(for: a) == session && tokens.session(for: b) == session)
        tokens.revoke(session)
        #expect(tokens.session(for: a) == nil && tokens.session(for: b) == nil)
    }

    private static func testPath() -> String {
        MCPSocket.path(dataFolder: URL(filePath: "/agh-mcp-test/\(UUID())"))
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            try #require(Date.now < deadline)
            usleep(10_000)
        }
    }
}

/// A running `agenthesia-mcp` with pipes for its standard input and output.
private final class Helper {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let exit: AsyncStream<Int32>
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(socket: String, token: String) throws {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let executable = try #require(
            [".build/debug/agenthesia-mcp", ".build/out/Products/Debug/agenthesia-mcp"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        process.executableURL = executable
        process.environment = ["AGENTHESIA_MCP_SOCKET": socket, "AGENTHESIA_MCP_TOKEN": token]
        process.standardInput = input
        process.standardOutput = output
        let (exit, continuation) = AsyncStream<Int32>.makeStream()
        self.exit = exit
        process.terminationHandler = {
            continuation.yield($0.terminationStatus)
            continuation.finish()
        }
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try process.run()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func line() async throws -> String? {
        try await lines.next()
    }

    func closeInput() throws {
        try input.fileHandleForWriting.close()
    }

    func status() async -> Int32? {
        await exit.first { _ in true }
    }
}
