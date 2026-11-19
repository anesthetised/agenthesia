import ACP
import Foundation
import JSONRPC
import Workspace

/// One session's ACP filesystem. Accepted operations finish before close returns.
///
/// Reads go anywhere, writes stay inside the session's roots (ADR-0052).
@MainActor final class SessionFileSystem: ACP.FileSystemProvider {
    /// Bounds the memory one read takes now that reads reach the whole disk. Larger than the preview's 2 MiB, which a
    /// lock file or a generated source in the checkout can exceed.
    nonisolated static let maximumReadBytes = 16 * 1024 * 1024
    /// The root `/` keeps every check of `ScopedFileAccess` but its scope.
    private static let reader = ScopedFileAccess(roots: [URL(filePath: "/", directoryHint: .isDirectory)])
    private weak var controller: SessionController?
    private let access: ScopedFileAccess
    /// The roots as the agent was given them, for the error of a refused write.
    private let rootPaths: [String]
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
        rootPaths = paths
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
        try await perform(in: sessionId, with: Self.reader) {
            try $0.readText(at: path, line: line, limit: limit, maximumBytes: Self.maximumReadBytes)
        }
    }

    @MainActor func writeTextFile(at path: String, content: String, in sessionId: ACP.SessionID) async throws {
        try await perform(in: sessionId, with: access) { try $0.writeText(content, to: path) }
        controller?.fileDidChange()
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
        with access: ScopedFileAccess,
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
        do {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try operation(access) }) }
            }
        } catch let error as ScopedFileAccess.Failure {
            throw Self.rpcError(error, roots: rootPaths)
        }
    }

    /// `roots` are the writable folders; only a write can be outside them.
    static func rpcError(_ failure: ScopedFileAccess.Failure, roots: [String]) -> RPCError {
        switch failure {
        case .notAbsolute(let path): .invalidParams("Path must be absolute: \(path)")
        case .outsideScope:
            .invalidParams("Writes are limited to the session's folders: \(roots.joined(separator: ", "))")
        case .notFound(let path): RPCError(code: RPCError.resourceNotFoundCode, message: "Not found: \(path)")
        case .notText(let path): .invalidParams("Not a UTF-8 text file: \(path)")
        case .invalidPath: .invalidParams("Path contains a NUL byte")
        case .notRegularFile(let path): .invalidParams("Not a regular file: \(path)")
        case .io(let path, EFBIG): .invalidParams("File is larger than \(maximumReadBytes / 1_048_576) MiB: \(path)")
        case .io(let path, let code):
            RPCError(code: RPCError.internalErrorCode, message: "File operation failed (\(code)): \(path)")
        }
    }
}
