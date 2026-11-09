import Darwin
import Foundation

// The agenthesia MCP server's stdio end (ADR-0049). An agent starts it as a stdio MCP server; it connects to the app's
// socket (AGENTHESIA_MCP_SOCKET), sends the session's token (AGENTHESIA_MCP_TOKEN) as its first line, then relays
// bytes between its stdio and the socket without parsing them. It exits when either side closes.

func fail(_ message: String) -> Never {
    fputs("agenthesia-mcp: \(message)\n", stderr)
    exit(1)
}

/// Writes all of `bytes`; false once the descriptor is closed or fails.
func writeAll(_ bytes: ArraySlice<UInt8>, to descriptor: Int32) -> Bool {
    var rest = bytes
    while !rest.isEmpty {
        let written = rest.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { return false }
        rest = rest.dropFirst(written)
    }
    return true
}

/// Copies bytes until either descriptor closes, then exits.
func relay(from source: Int32, to destination: Int32) -> Never {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0, writeAll(buffer[..<count], to: destination) else { exit(0) }
    }
}

guard let path = getenv("AGENTHESIA_MCP_SOCKET").map({ String(cString: $0) }),
    let token = getenv("AGENTHESIA_MCP_TOKEN").map({ String(cString: $0) })
else { fail("AGENTHESIA_MCP_SOCKET and AGENTHESIA_MCP_TOKEN must be set") }

// A closed peer must end the relay with EPIPE, not kill the helper silently.
signal(SIGPIPE, SIG_IGN)
let app = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8)
guard app >= 0, pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("cannot use \(path)") }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(app, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail("cannot connect to \(path): \(String(cString: strerror(errno)))") }
guard writeAll(ArraySlice((token + "\n").utf8), to: app) else { fail("cannot send the hello") }

Thread.detachNewThread { [app] in relay(from: app, to: STDOUT_FILENO) }
relay(from: STDIN_FILENO, to: app)
