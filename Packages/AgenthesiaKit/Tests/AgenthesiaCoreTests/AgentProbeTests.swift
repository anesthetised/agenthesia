import ACP
import AgentRuntime
import Foundation
import Testing

@testable import AgenthesiaCore

@Suite(.timeLimit(.minutes(1))) struct AgentProbeTests {
    @Test func initializesAnAgentInAnEmptyDirectoryAndStopsIt() async throws {
        let profile = try await AgentProbe.run(AgentCommand(executable: try mockAgent(), arguments: ["--auth"]))
        #expect(profile.info?.name == "echo-agent")
        #expect(profile.info?.version == "1.0.0")
        #expect(profile.protocolVersion == 1)
        #expect(!profile.authMethods.isEmpty)
    }

    @Test func aSilentCommandTimesOutAndIsTerminated() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "agh-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = "trap 'touch \"$1\"; exit 0' TERM; while :; do sleep 0.1; done"
        let start = ContinuousClock.now
        await #expect(throws: AgentProbe.Failure.timedOut(seconds: 0)) {
            try await AgentProbe.run(
                AgentCommand(
                    executable: "/bin/sh",
                    arguments: ["-c", script, "sh", marker.path(percentEncoded: false)]
                ),
                timeout: .milliseconds(300)
            )
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test func aCommandThatExitsReportsItsStatusAndLastErrorLine() async throws {
        await #expect(throws: AgentProbe.Failure.closed(.exited(3), stderr: "unknown command acp")) {
            try await AgentProbe.run(
                AgentCommand(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo usage >&2; echo unknown command acp >&2; exit 3"]
                )
            )
        }
    }

    @Test func answersThatAreNotV1AreExplained() async throws {
        let unsupported = #"read line; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2}}'; sleep 5"#
        await #expect(throws: AgentProbe.Failure.unsupportedProtocol(2)) {
            try await AgentProbe.run(AgentCommand(executable: "/bin/sh", arguments: ["-c", unsupported]))
        }
        let error =
            #"read line; echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}'; sleep 5"#
        let failure = await #expect(throws: AgentProbe.Failure.self) {
            try await AgentProbe.run(AgentCommand(executable: "/bin/sh", arguments: ["-c", error]))
        }
        guard case .notACP(let reason) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(reason.contains("Method not found"))
    }

    @Test func aMissingExecutableFailsToLaunch() async throws {
        let failure = await #expect(throws: AgentProbe.Failure.self) {
            try await AgentProbe.run(AgentCommand(executable: "/nonexistent/agent"))
        }
        guard case .launchFailed = failure else { Issue.record("\(String(describing: failure))"); return }
    }

    private func mockAgent() throws -> String {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        return try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ).path(percentEncoded: false)
    }
}
