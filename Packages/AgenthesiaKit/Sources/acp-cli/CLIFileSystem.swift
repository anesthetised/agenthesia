import ACP
import Foundation
import JSONRPC
import Workspace

/// Serves `fs/*` for agents, confined to the working directory.
struct CLIFileSystem: ACP.FileSystemProvider {
    let access: ScopedFileAccess

    init(root: URL) {
        access = ScopedFileAccess(roots: [root])
    }

    func readTextFile(at path: String, line: Int?, limit: Int?, in sessionId: ACP.SessionID) async throws -> String {
        do {
            return try access.readText(at: path, line: line, limit: limit)
        } catch {
            throw Self.rpcError(error)
        }
    }

    func writeTextFile(at path: String, content: String, in sessionId: ACP.SessionID) async throws {
        do {
            try access.writeText(content, to: path)
        } catch {
            throw Self.rpcError(error)
        }
    }

    static func rpcError(_ failure: ScopedFileAccess.Failure) -> RPCError {
        switch failure {
        case .notAbsolute(let path): .invalidParams("Path must be absolute: \(path)")
        case .outsideScope(let path): .invalidParams("Path is outside the working directory: \(path)")
        case .notFound(let path): RPCError(code: RPCError.resourceNotFoundCode, message: "Not found: \(path)")
        case .notText(let path): .invalidParams("Not a UTF-8 text file: \(path)")
        case .invalidPath: .invalidParams("Path contains a NUL byte")
        case .notRegularFile(let path): .invalidParams("Not a regular file: \(path)")
        case .io(let path, let code): RPCError(code: -32603, message: "File operation failed (\(code)): \(path)")
        }
    }
}
