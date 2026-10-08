public import Foundation
public import JSONRPC

extension ACP.V1 {
    /// Handles what an ACP v1 agent asks of the client.
    ///
    /// Every method has a default: requests fail with `-32601` and notifications are ignored, so a client
    /// only implements what it advertises in its capabilities.
    public protocol ClientDelegate: Sendable {
        func sessionUpdate(_ notification: SessionNotification) async
        func sessionUpdate(_ notification: SessionNotification, rawNotification: Data) async
        func requestPermission(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse
        func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse
        func writeTextFile(_ request: WriteTextFileRequest) async throws -> EmptyMessage
        func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse
        func terminalOutput(_ request: TerminalRequest) async throws -> TerminalOutputResponse
        func waitForTerminalExit(_ request: TerminalRequest) async throws -> TerminalExitStatus
        func killTerminal(_ request: TerminalRequest) async throws -> EmptyMessage
        func releaseTerminal(_ request: TerminalRequest) async throws -> EmptyMessage
        func createElicitation(_ request: ACP.ElicitationRequest) async throws -> ACP.ElicitationResponse
        func completeElicitation(_ notification: ACP.ElicitationComplete) async
    }
}

extension ACP.V1.ClientDelegate {
    public func sessionUpdate(_ notification: ACP.V1.SessionNotification, rawNotification: Data) async {
        await sessionUpdate(notification)
    }

    public func sessionUpdate(_ notification: ACP.V1.SessionNotification) async {}

    public func requestPermission(
        _ request: ACP.V1.RequestPermissionRequest
    ) async throws -> ACP.V1.RequestPermissionResponse {
        throw RPCError.methodNotFound(ACP.V1.Method.RequestPermission.method)
    }

    public func readTextFile(_ request: ACP.V1.ReadTextFileRequest) async throws -> ACP.V1.ReadTextFileResponse {
        throw RPCError.methodNotFound(ACP.V1.Method.ReadTextFile.method)
    }

    public func writeTextFile(_ request: ACP.V1.WriteTextFileRequest) async throws -> ACP.V1.EmptyMessage {
        throw RPCError.methodNotFound(ACP.V1.Method.WriteTextFile.method)
    }

    public func createTerminal(_ request: ACP.V1.CreateTerminalRequest) async throws -> ACP.V1.CreateTerminalResponse {
        throw RPCError.methodNotFound(ACP.V1.Method.CreateTerminal.method)
    }

    public func terminalOutput(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalOutputResponse {
        throw RPCError.methodNotFound(ACP.V1.Method.TerminalOutput.method)
    }

    public func waitForTerminalExit(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalExitStatus {
        throw RPCError.methodNotFound(ACP.V1.Method.WaitForTerminalExit.method)
    }

    public func killTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
        throw RPCError.methodNotFound(ACP.V1.Method.KillTerminal.method)
    }

    public func releaseTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
        throw RPCError.methodNotFound(ACP.V1.Method.ReleaseTerminal.method)
    }

    public func createElicitation(_ request: ACP.ElicitationRequest) async throws -> ACP.ElicitationResponse {
        throw RPCError.methodNotFound(ACP.V1.Method.CreateElicitation.method)
    }

    public func completeElicitation(_ notification: ACP.ElicitationComplete) async {}
}

extension ACP.V1 {
    /// A router that dispatches every agent → client method of ACP v1 to `delegate`.
    public static func router(for delegate: some ClientDelegate) -> Router {
        var router = Router()
        router.on(Method.SessionUpdate.self) { await delegate.sessionUpdate($0) }
        router.onRawNotification(Method.SessionUpdate.self) { raw in
            let recorded = try ACP.RecordedSessionUpdate(rawNotification: raw)
            await delegate.sessionUpdate(
                .init(sessionId: recorded.sessionId, update: recorded.update, meta: recorded.meta),
                rawNotification: raw
            )
        }
        router.on(Method.RequestPermission.self) { try await delegate.requestPermission($0) }
        router.on(Method.ReadTextFile.self) { try await delegate.readTextFile($0) }
        router.on(Method.WriteTextFile.self) { try await delegate.writeTextFile($0) }
        router.on(Method.CreateTerminal.self) { try await delegate.createTerminal($0) }
        router.on(Method.TerminalOutput.self) { try await delegate.terminalOutput($0) }
        router.on(Method.WaitForTerminalExit.self) { try await delegate.waitForTerminalExit($0) }
        router.on(Method.KillTerminal.self) { try await delegate.killTerminal($0) }
        router.on(Method.ReleaseTerminal.self) { try await delegate.releaseTerminal($0) }
        router.on(Method.CreateElicitation.self) { try await delegate.createElicitation($0) }
        router.on(Method.CompleteElicitation.self) { await delegate.completeElicitation($0) }
        return router
    }
}
