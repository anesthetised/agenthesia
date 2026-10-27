import Darwin
import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct CommandOutputTests {
    @Test func cancellationStopsTheProcessGroupBeforeTheCaptureDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-capture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appending(path: "ready")
        let task = Task {
            await CommandOutput.capture(
                .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "/bin/sleep 30 & echo $! > \"$1\"; wait", "capture", ready.path],
                    environment: ["PATH": "/usr/bin:/bin"]
                ),
                timeout: .seconds(30)
            )
        }
        defer { task.cancel() }
        let child = try await waitForChildPID(at: ready)
        defer { kill(child, SIGKILL) }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(cancelledAt.duration(to: .now) < .seconds(10))
        #expect(try await waitUntilInactive(child))
    }

    @Test func capturesOutputStatusEnvironmentAndDirectory() async {
        let command = AgentCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$VALUE\" \"$PWD\"; exit 7"],
            environment: ["VALUE": "a b"],
            currentDirectory: URL(filePath: "/private/tmp")
        )
        let result = await CommandOutput.capture(command, timeout: .seconds(2), limit: 1024)
        #expect(result == .success(Data("a b:/private/tmp".utf8), 7 << 8))
    }

    @Test func boundsOutputAndTimeAndRejectsInvalidLaunch() async {
        #expect(
            await CommandOutput.capture(
                .init(executable: "/bin/sh", arguments: ["-c", "printf 123456"]),
                limit: 3
            ) == .tooMuchOutput
        )
        #expect(
            await CommandOutput.capture(
                .init(executable: "/bin/sleep", arguments: ["5"]),
                timeout: .milliseconds(50)
            ) == .timedOut
        )
        #expect(await CommandOutput.capture(.init(executable: "/missing/agenthesia-command")) == .launchFailed)
        #expect(
            await CommandOutput.capture(
                .init(executable: "/bin/echo", arguments: ["bad\0argument"])
            ) == .launchFailed
        )
        #expect(
            await CommandOutput.capture(
                .init(executable: "/bin/echo", currentDirectory: URL(filePath: "/missing/agenthesia-cwd"))
            ) == .launchFailed
        )
    }
}
