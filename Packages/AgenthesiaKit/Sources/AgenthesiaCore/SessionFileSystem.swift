import ACP
import Foundation
import JSONRPC
import Workspace

/// One session's ACP filesystem. Accepted operations finish before close returns.
@MainActor final class SessionFileSystem: ACP.FileSystemProvider {
    private weak var controller: SessionController?
    private let access: ScopedFileAccess
    private let queue: DispatchQueue
    private var closed = false
    private(set) var pendingOperations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(controller: SessionController, queue: DispatchQueue? = nil) async throws {
        self.controller = controller
        self.queue = queue ?? DispatchQueue(label: "Agenthesia.SessionFileSystem", qos: .userInitiated)
        let paths = [controller.session.workingDirectory] + controller.additionalDirectories
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            throw LiveSession.LaunchError(message: "Filesystem roots must be absolute paths without NUL bytes")
        }
        let roots = paths.map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        access = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let access = ScopedFileAccess(roots: roots)
                        for root in access.roots {
                            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                                throw LiveSession.LaunchError(
                                    message: "Filesystem roots must be existing directories: \(root.path)"
                                )
                            }
                        }
                        return access
                    }
                )
            }
        }
    }

    func readTextFile(at path: String, line: Int?, limit: Int?, in sessionId: ACP.SessionID) async throws -> String {
        try await perform(in: sessionId) { try $0.readText(at: path, line: line, limit: limit) }
    }

    func writeTextFile(at path: String, content: String, in sessionId: ACP.SessionID) async throws {
        try await perform(in: sessionId) { try $0.writeText(content, to: path) }
    }

    func stopAccepting() { closed = true }

    func close() async {
        stopAccepting()
        if pendingOperations > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func perform<Value: Sendable>(
        in sessionId: ACP.SessionID,
        _ operation: @escaping @Sendable (ScopedFileAccess) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !closed, let controller, controller.session.agentSessionID == sessionId,
            controller.status == .idle || controller.status == .running
        else { throw RPCError.invalidParams("Filesystem access is unavailable for this session") }
        pendingOperations += 1
        defer {
            pendingOperations -= 1
            if pendingOperations == 0 {
                let completed = waiters
                waiters.removeAll()
                for waiter in completed { waiter.resume() }
            }
        }
        let access = access
        do {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try operation(access) }) }
            }
        } catch let error as ScopedFileAccess.Failure {
            throw Self.rpcError(error)
        }
    }

    static func rpcError(_ failure: ScopedFileAccess.Failure) -> RPCError {
        switch failure {
        case .notAbsolute(let path): .invalidParams("Path must be absolute: \(path)")
        case .outsideScope(let path): .invalidParams("Path is outside the session's filesystem roots: \(path)")
        case .notFound(let path): RPCError(code: RPCError.resourceNotFoundCode, message: "Not found: \(path)")
        case .notText(let path): .invalidParams("Not a UTF-8 text file: \(path)")
        case .invalidPath: .invalidParams("Path contains a NUL byte")
        case .notRegularFile(let path): .invalidParams("Not a regular file: \(path)")
        case .io(let path, let code):
            RPCError(code: RPCError.internalErrorCode, message: "File operation failed (\(code)): \(path)")
        }
    }
}
