/// JSON-RPC 2.0 over newline-delimited streams.
///
/// This module knows nothing about ACP. See docs/ARCHITECTURE.md.
public enum JSONRPC {
    /// The protocol version carried in every message's `jsonrpc` field.
    public static let version = "2.0"
}
