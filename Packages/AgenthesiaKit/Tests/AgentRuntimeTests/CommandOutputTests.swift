import Darwin
import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct CommandOutputTests {
    @Test(arguments: [0, 4])
    func cancellationStopsTheProcessGroupBeforeTheCaptureDeadline(startupDelay: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-capture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appending(path: "ready")
        try await withThrowingTaskGroup(of: CaptureEvent.self) { group in
            group.addTask {
                .completed(
                    await CommandOutput.capture(
                        .init(
                            executable: "/bin/sh",
                            arguments: [
                                "-c", "/bin/sleep \"$2\"; /bin/sleep 30 & echo $! > \"$1\"; wait", "capture",
                                ready.path,
                                String(startupDelay),
                            ],
                            environment: ["PATH": "/usr/bin:/bin"]
                        ),
                        timeout: .seconds(30)
                    )
                )
            }
            group.addTask { .ready(try await waitForChildPID(at: ready, deadline: nil)) }
            defer { group.cancelAll() }
            // Capture completion bounds readiness and reports launch failures without a second startup deadline.
            let first = try #require(await group.next())
            guard case .ready(let child) = first else {
                Issue.record("Capture completed before the child became ready: \(first)")
                return
            }
            defer { kill(child, SIGKILL) }
            let cancelledAt = ContinuousClock.now
            group.cancelAll()
            #expect(try await group.next() == .completed(.cancelled))
            #expect(cancelledAt.duration(to: .now) < .seconds(10))
            #expect(try await waitUntilInactive(child))
        }
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

private enum CaptureEvent: Equatable, Sendable {
    case ready(Int32)
    case completed(CommandOutput)
}
