import Foundation
import Synchronization
import Testing

/// Executables built next to the tests.
enum Binaries {
    static func find(_ name: String) -> URL? {
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let candidates =
            Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appending(path: name) } + [
                packageRoot.appending(path: ".build/out/Products/Debug/\(name)"),
                packageRoot.appending(path: ".build/debug/\(name)"),
            ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    static let cli = find("acp-cli")
    static let mockAgent = find("MockAgent")
    static var available: Bool { cli != nil && mockAgent != nil }
}

/// acp-cli running against MockAgent, driven through its stdin.
final class CLIRun: Sendable {
    let process: Process
    private let stdin: FileHandle
    private let output = Output()

    init(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = try #require(Binaries.cli)
        let agent = try #require(Binaries.mockAgent).path(percentEncoded: false)
        process.arguments = arguments + ["--cwd", cwd.path(percentEncoded: false), "--", agent]
        process.environment = childEnvironment()
        let input = Pipe()
        let stdout = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stdout
        stdin = input.fileHandleForWriting
        self.process = process
        let output = output
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.append(String(decoding: data, as: UTF8.self))
            }
        }
        try process.run()
    }

    var text: String { output.text }

    func type(_ line: String) throws {
        try stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    func waitFor(_ needle: String, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !text.contains(needle) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \"\(needle)\". Output:\n\(text)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForExit() async -> Int32 {
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.terminationStatus
    }
}

@Suite(.timeLimit(.minutes(1)), .enabled(if: Binaries.available, "acp-cli and MockAgent have not been built"))
struct EndToEndTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "acp-cli-e2e-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "from disk".write(to: directory.appending(path: "in.txt"), atomically: true, encoding: .utf8)
    }

    private func path(_ name: String) -> String {
        directory.appending(path: name).path(percentEncoded: false)
    }

    @Test func chatsReadsWritesAndQuits() async throws {
        let run = try CLIRun(["chat"], cwd: directory)
        try await run.waitFor("Connected to Echo Agent 1.0.0")
        try await run.waitFor("Options: Mode=Ask, Model=Small")
        try run.type("hello")
        try await run.waitFor("Echo: hello")
        try run.type("read \(path("in.txt"))")
        try await run.waitFor("from disk")
        try run.type("write \(path("out.txt")) written")
        try await run.waitFor("Permission requested: Write \(path("out.txt"))")
        try run.type("1")
        try await run.waitFor("Echo: write")
        #expect(try String(contentsOfFile: path("out.txt"), encoding: .utf8) == "written")
        try run.type("fail")
        try await run.waitFor("Error -32603")
        try run.type("/quit")
        #expect(await run.waitForExit() == 0)
    }

    @Test func ctrlCCancelsTheTurnThenQuits() async throws {
        let run = try CLIRun(["chat"], cwd: directory)
        try await run.waitFor("Connected")
        try run.type("slow")
        try await run.waitFor("…")
        kill(run.process.processIdentifier, SIGINT)
        try await run.waitFor("— cancelled")
        kill(run.process.processIdentifier, SIGINT)
        #expect(await run.waitForExit() == 130)
    }

    @Test func listsSessionsAndSignsIn() async throws {
        let sessions = try CLIRun(["sessions"], cwd: directory)
        #expect(await sessions.waitForExit() == 0)
        #expect(sessions.text.contains("No sessions."))

        let methods = try CLIRun(["login"], cwd: directory)
        #expect(await methods.waitForExit() == 0)
        #expect(methods.text.contains("mock-login  Mock login"))

        let login = try CLIRun(["login", "--method", "mock-login"], cwd: directory)
        #expect(await login.waitForExit() == 0)
        #expect(login.text.contains("Signed in."))
    }
}

/// Output collected from a child process's pipe.
final class Output: Sendable {
    private let buffer = Mutex("")

    func append(_ text: String) {
        buffer.withLock { $0 += text }
    }

    var text: String { buffer.withLock { $0 } }
}

/// The environment for instrumented child processes: they write coverage profiles next to the test
/// runner's when coverage is enabled, and to a temporary directory otherwise, never to the working directory.
func childEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if environment["LLVM_PROFILE_FILE"] == nil {
        environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory
            .appending(path: "agenthesia-child-%p.profraw").path(percentEncoded: false)
    }
    return environment
}
