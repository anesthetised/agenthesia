public import ACP
public import AgentRuntime
public import Foundation
import JSONRPC

/// Launches a command, sends ACP `initialize` and stops it again, without creating a session (ADR-0037).
/// The agent runs in an empty temporary directory; a passed check does not mean the user is signed in.
public enum AgentProbe {
    public enum Failure: Error, Equatable, LocalizedError {
        case launchFailed(String)
        case timedOut(seconds: Int)
        case closed(ExitStatus, stderr: String?)
        case unsupportedProtocol(Int)
        case notACP(String)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "The command could not start: \(reason)"
            case .timedOut(let seconds): "The command did not answer ACP initialize within \(seconds) seconds."
            case .closed(let status, let stderr):
                "The command \(status) without answering ACP initialize.\(stderr.map { " \($0)" } ?? "")"
            case .unsupportedProtocol(let version):
                "The agent speaks ACP version \(version); Agenthesia supports version 1."
            case .notACP(let reason): "The command did not answer as an ACP agent: \(reason)"
            }
        }
    }

    public static func run(_ command: AgentCommand, timeout: Duration = .seconds(20)) async throws -> ACP.AgentProfile {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agenthesia-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = command
        command.currentDirectory = directory
        let process: AgentProcess
        do {
            process = try await Task.detached { [command] in try AgentProcess(launching: command) }.value
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: process.transport, delegate: Silent())
        let result: Result<ACP.AgentProfile?, any Error>
        do {
            result = .success(
                try await withThrowingTaskGroup(of: ACP.AgentProfile?.self) { group in
                    group.addTask { try await connection.initialize(client: .init(name: "Agenthesia", version: "0.1")) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    defer { group.cancelAll() }
                    // Closing fails the pending request, so the group does not wait for an agent that never answers.
                    do {
                        let first = try await group.next() ?? nil
                        await connection.close()
                        return first
                    } catch {
                        await connection.close()
                        throw error
                    }
                }
            )
        } catch {
            result = .failure(error)
        }
        let status = await process.terminate(gracePeriod: .seconds(1))
        switch result {
        case .success(let profile?): return profile
        case .success(nil): throw Failure.timedOut(seconds: Int(timeout.components.seconds))
        case .failure(let error as CancellationError): throw error
        case .failure(let error as ConnectionError) where error == .closed:
            let lastLine = await process.stderrLog.split(whereSeparator: \.isNewline).last.map {
                String($0.prefix(300))
            }
            throw Failure.closed(status, stderr: lastLine)
        case .failure(ACP.V1.ClientError.unsupportedProtocolVersion(let version)):
            throw Failure.unsupportedProtocol(version)
        case .failure(let error as RPCError): throw Failure.notACP("\(error.message) (\(error.code))")
        case .failure(let error): throw Failure.notACP(error.localizedDescription)
        }
    }

    /// A probe opens no session, so nothing arrives for one.
    private struct Silent: ACP.AgentConnectionDelegate {
        func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {}
        func requestPermission(
            for toolCall: ACP.ToolCallUpdate,
            options: [ACP.PermissionOption],
            in sessionId: ACP.SessionID
        ) async -> ACP.PermissionOutcome { .cancelled }
    }
}
