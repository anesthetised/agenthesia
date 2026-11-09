import CryptoKit
import Darwin
public import Foundation
public import JSONRPC

/// The app's end of the `agenthesia-mcp` helper (ADR-0049): one Unix socket per app instance. A connection opens with
/// a hello line holding a session token; a live session's token hands the rest of the connection, newline-delimited
/// JSON-RPC, to `serve` with that session, and any other closes it. The connection closes when `serve` returns.
public final class MCPSocket {
    public typealias Serve = @Sendable (UUID, any MessageTransport) async -> Void

    public let path: String
    private let source: any DispatchSourceRead

    /// Listens at `path` with mode `0600`, replacing a stale socket an earlier instance left there.
    public init(path: String, tokens: MCPTokens, serve: @escaping Serve) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError.current }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Until `listen`, a connection is refused, so nobody connects before the mode is set.
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, SOMAXCONN) == 0 else {
            let error = POSIXError.current
            Darwin.close(listener)
            unlink(path)
            throw error
        }

        self.path = path
        source = DispatchSource.makeReadSource(
            fileDescriptor: listener,
            queue: DispatchQueue(label: "io.github.anesthetised.Agenthesia.MCPSocket")
        )
        source.setEventHandler {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // The hello is read with a blocking read, outside the cooperative pool.
            DispatchQueue.global().async {
                guard let token = Self.hello(client), let session = tokens.session(for: token) else {
                    Darwin.close(client)
                    return
                }
                let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
                let transport = FileHandleTransport(reading: handle, writing: handle)
                Task {
                    await serve(session, transport)
                    await transport.close()
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(listener)
            unlink(path)
        }
        source.resume()
    }

    /// Stops listening and removes the socket. Open connections stay until their `serve` returns.
    public func close() {
        source.cancel()
    }

    /// `$TMPDIR/agenthesia-<16 hex digits>.sock`, the digits from a SHA-256 of `dataFolder`: per user, short enough
    /// for `sun_path`, and apart for every data folder (the installed app, the `.dev` build, a `CFFIXED_USER_HOME` run).
    public static func path(dataFolder: URL) -> String {
        let digest = SHA256.hash(data: Data(dataFolder.standardizedFileURL.path(percentEncoded: false).utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appending(path: "agenthesia-\(name).sock")
            .path(percentEncoded: false)
    }

    /// The first line of a connection, read a byte at a time so nothing after it is consumed. Nil after 5 seconds,
    /// 256 bytes or the end of the connection.
    private static func hello(_ client: Int32) -> String? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < 256, read(client, &byte, 1) == 1 {
            guard byte != 0x0A else {
                timeout = timeval()
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
        return nil
    }
}

extension POSIXError {
    fileprivate static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
