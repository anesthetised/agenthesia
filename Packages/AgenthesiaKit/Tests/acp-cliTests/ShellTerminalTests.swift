import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)), .enabled(if: Binaries.available, "acp-cli and MockAgent have not been built"))
struct ShellTerminalTests {
    @Test func loginShellEnvironmentWorksUnderControllingTerminal() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agenthesia-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = "agenthesia-pty-agent-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: command),
            withDestinationURL: try #require(Binaries.mockAgent)
        )
        try "export PATH='\(bin.path(percentEncoded: false))':$PATH\n".write(
            to: home.appending(path: ".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", try #require(Binaries.cli).path(percentEncoded: false), "sessions", "--", command,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path(percentEncoded: false)
        environment["ZDOTDIR"] = home.path(percentEncoded: false)
        environment["SHELL"] = "/bin/zsh"
        environment["PATH"] = "/usr/bin:/bin"
        environment.removeValue(forKey: "ENV")
        environment.removeValue(forKey: "BASH_ENV")
        if environment["LLVM_PROFILE_FILE"] == nil {
            environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory
                .appending(path: "agenthesia-child-%p.profraw").path(percentEncoded: false)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let collected = Output()
        let outputEnded = Mutex(false)
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                outputEnded.withLock { $0 = true }
            } else {
                collected.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        try process.run()
        output.fileHandleForWriting.closeFile()
        let pid = process.processIdentifier
        defer {
            if process.isRunning { kill(pid, SIGKILL) }
            output.fileHandleForReading.readabilityHandler = nil
        }
        let deadline = ContinuousClock.now + .seconds(12)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            let group = getpgid(pid)
            kill(group == pid ? -pid : pid, SIGTERM)
            try await Task.sleep(for: .milliseconds(100))
            if process.isRunning { kill(group == pid ? -pid : pid, SIGKILL) }
            Issue.record("PTY CLI did not exit. Output: \(collected.text)")
            return
        }
        let outputDeadline = ContinuousClock.now + .seconds(1)
        while !outputEnded.withLock({ $0 }) && ContinuousClock.now < outputDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outputEnded.withLock { $0 })
        #expect(process.terminationStatus == 0)
        #expect(collected.text.contains("No sessions."), "Output: \(collected.text)")
        #expect(!collected.text.contains("using the inherited environment"))
    }
}
