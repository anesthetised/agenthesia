public import Foundation
import Synchronization

/// The tokens of live sessions for the `agenthesia-mcp` helper (ADR-0049). A token names its session while the session
/// is live; revoking the session kills it, and Continue issues a new one.
public final class MCPTokens: Sendable {
    private let sessions = Mutex<[String: UUID]>([:])

    public init() {}

    /// A new token for `session`: 256 bits from `SystemRandomNumberGenerator` (`arc4random_buf`) as 64 hex digits.
    public func issue(for session: UUID) -> String {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<4).map { _ in
            let word = String(generator.next() as UInt64, radix: 16)
            return String(repeating: "0", count: 16 - word.count) + word
        }.joined()
        sessions.withLock { $0[token] = session }
        return token
    }

    /// Revokes every token of `session`.
    public func revoke(_ session: UUID) {
        sessions.withLock { $0 = $0.filter { $0.value != session } }
    }

    /// The live session `token` names, if any.
    public func session(for token: String) -> UUID? {
        sessions.withLock { $0[token] }
    }
}
