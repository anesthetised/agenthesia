/// Agent Client Protocol: wire types, client API and the version-agnostic `AgentConnection`.
///
/// See docs/adr/0003-own-acp-implementation.md.
public enum ACP {
    /// Wire types and adapter for ACP v1.
    public enum V1 {
        /// The protocol version sent in `initialize`.
        public static let protocolVersion = 1
    }
}
