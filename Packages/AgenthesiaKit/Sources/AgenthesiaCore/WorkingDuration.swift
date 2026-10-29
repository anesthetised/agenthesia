public import Foundation

/// How long a turn has been running, as shown under the transcript.
public enum WorkingDuration {
    /// `12s`, `1m 12s`, `1h 2m`; whole seconds, never negative.
    public static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
