import ACP
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

/// Signing in to a real MockAgent process from a session that waits for it (ADR-0033).
@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveSessionSignInTests {
    private struct Fixture {
        let directory: URL
        let library: SessionLibrary
        let project: URL
        let signInFile: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "live-sign-in-\(UUID())")
            project = directory.appending(path: "project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            library = SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite"))
            signInFile = directory.appending(path: "signed-in")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func agent() throws -> AgentInstallRecord {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentInstallRecord(
                name: "Mock",
                executable: binary.path,
                arguments: ["--auth", "--auth-file", signInFile.path(percentEncoded: false), "--reopen"]
            )
        }

        @MainActor func owner() -> LiveSession {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            return owner
        }
    }

    /// Starts a session that stops at sign-in, with both kinds of method offered.
    private func startSignedOut(_ fixture: Fixture) async throws -> LiveSession {
        let owner = fixture.owner()
        await owner.start(directory: fixture.project, agent: try fixture.agent())
        let signIn = try #require(owner.signIn)
        #expect(signIn.methods.compactMap(\.id) == ["mock-login", "mock-terminal"])
        #expect(signIn.message == nil)
        #expect(owner.errorMessage == nil)
        #expect(owner.isLive)
        #expect(!owner.isStarting)
        #expect(owner.activity == .needsInput)
        #expect(owner.controller?.status == .ready)
        #expect(try await fixture.library.history().isEmpty)
        return owner
    }

    /// Runs a terminal sign-in, answering MockAgent's question once it is asked.
    private func signInOnTerminal(_ owner: LiveSession, answer: String) async throws {
        let signingIn = Task { await owner.signIn(with: "mock-terminal") }
        let terminal = try await waitFor { owner.signInTerminal }
        #expect(owner.signIn?.pending == "mock-terminal")
        #expect(terminal.title == "Mock terminal login")
        var output = ""
        for await chunk in terminal.output() {
            output += String(decoding: chunk, as: UTF8.self)
            if output.contains("Type yes") { break }
        }
        terminal.write(Data("\(answer)\n".utf8))
        await signingIn.value
    }

    @Test func agentMethodSignsInOnTheSameConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        await owner.signIn(with: "mock-login")
        #expect(owner.signIn == nil)
        #expect(owner.controller?.status == .idle)
        #expect(owner.activity == .idle)
        #expect(try await fixture.library.history().count == 1)
        await owner.send("hello")
        #expect(owner.controller?.transcript.items.last?.message?.text == "Echo: hello")
        await owner.close()
    }

    @Test func terminalMethodRelaunchesTheAgentInTheSameWorkingDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        let directory = owner.workingDirectory
        try await signInOnTerminal(owner, answer: "yes")
        #expect(owner.signInTerminal == nil)
        #expect(owner.signIn == nil)
        #expect(owner.controller?.status == .idle)
        #expect(owner.workingDirectory == directory)
        #expect(try await fixture.library.history().count == 1)
        await owner.send("hello")
        #expect(owner.controller?.transcript.items.last?.message?.text == "Echo: hello")
        await owner.close()
    }

    @Test func failedTerminalSignInKeepsItsOutputUntilDismissed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        try await signInOnTerminal(owner, answer: "no")
        let terminal = try #require(owner.signInTerminal)
        #expect(terminal.exitMessage == "Sign-in exited with status 1.")
        #expect(owner.signIn?.pending == nil)
        #expect(owner.controller?.status == .ready)
        owner.dismissSignInTerminal()
        #expect(owner.signInTerminal == nil)
        // The agent was shut down for the terminal; an agent method launches it again first.
        await owner.signIn(with: "mock-login")
        #expect(owner.controller?.status == .idle)
        await owner.close()
    }

    @Test func signingInWithoutEffectAsksAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        try await signInOnTerminal(owner, answer: "skip")
        #expect(owner.signInTerminal == nil)
        #expect(owner.signIn?.message == "Mock still requires sign-in.")
        #expect(owner.signIn?.pending == nil)
        #expect(owner.controller?.status == .ready)
        #expect(try await fixture.library.history().isEmpty)
        await owner.close()
    }

    @Test func cancelStopsATerminalSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        let signingIn = Task { await owner.signIn(with: "mock-terminal") }
        _ = try await waitFor { owner.signInTerminal }
        await owner.cancelSignIn()
        await signingIn.value
        #expect(owner.signInTerminal == nil)
        #expect(owner.signIn?.pending == nil)
        #expect(owner.signIn?.message == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.signInFile.path(percentEncoded: false)))
        await owner.close()
    }

    @Test func closingEndsATerminalSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await startSignedOut(fixture)
        let signingIn = Task { await owner.signIn(with: "mock-terminal") }
        let terminal = try await waitFor { owner.signInTerminal }
        await owner.close()
        await signingIn.value
        #expect(terminal.exitMessage != nil)
        #expect(owner.activity != .needsInput)
        #expect(!owner.isLive)
    }

    @Test func continuingASavedSessionWaitsForSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        FileManager.default.createFile(atPath: fixture.signInFile.path(percentEncoded: false), contents: Data())
        let first = fixture.owner()
        await first.start(directory: fixture.project, agent: try fixture.agent())
        let session = try #require(first.controller?.session)
        await first.close()
        try FileManager.default.removeItem(at: fixture.signInFile)

        let owner = fixture.owner()
        await owner.resume(session)
        #expect(owner.signIn != nil)
        #expect(owner.activity == .needsInput)
        try await signInOnTerminal(owner, answer: "yes")
        #expect(owner.controller?.status == .idle)
        #expect(owner.controller?.transcript.items.last?.reopenedAt != nil)
        await owner.close()
    }

    private func waitFor<T>(_ value: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(value())
    }
}
