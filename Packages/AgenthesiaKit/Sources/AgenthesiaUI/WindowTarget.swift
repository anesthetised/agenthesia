public import Foundation

/// What a window shows; the value of the value-based `WindowGroup`, so macOS restores windows (ADR-0026).
public enum WindowTarget: Codable, Hashable, Sendable {
    case launch
    case session(UUID)
}

extension WindowTarget {
    static let scheme = "agenthesia"

    /// The URL that opens this target: notifications use it to lead back to a session (ADR-0030).
    var url: URL? {
        guard case .session(let id) = self else { return nil }
        return URL(string: "\(Self.scheme)://session/\(id.uuidString)")
    }

    /// Only well-formed session URLs are accepted; anything else is ignored.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == "session", url.pathComponents.count == 2,
            let id = UUID(uuidString: url.pathComponents[1])
        else { return nil }
        self = .session(id)
    }
}
