public import Foundation

/// What a window shows; the value of the value-based `WindowGroup`, so macOS restores windows (ADR-0026).
public enum WindowTarget: Codable, Hashable, Sendable {
    case launch
    case session(UUID)
}
