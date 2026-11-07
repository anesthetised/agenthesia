public import Foundation
import Observation
public import Workspace

/// The files of one session's review that the user marked as viewed (ADR-0041). A mark stays only while the file
/// looks as it did when it was read; it lives as long as the window, never in the append-only log.
@MainActor @Observable public final class ViewedMarks {
    /// What `stat` says about a changed file: a file that differs afterwards is unread again. A `touch` clears the
    /// mark too, which is the safe direction. A deleted file has no size and no modification time.
    public struct Fingerprint: Sendable, Equatable {
        public let status: SessionWorkspace.Review.Change.Status
        public let size: Int?
        public let modified: Date?

        public init(status: SessionWorkspace.Review.Change.Status, size: Int?, modified: Date?) {
            self.status = status
            self.size = size
            self.modified = modified
        }

        /// `lstat`, so a symbolic link is fingerprinted as itself.
        public nonisolated static func read(
            _ change: SessionWorkspace.Review.Change,
            in root: URL
        ) -> Fingerprint {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appending(path: change.path).path)
            return Fingerprint(
                status: change.status,
                size: (attributes?[.size] as? NSNumber)?.intValue,
                modified: attributes?[.modificationDate] as? Date
            )
        }
    }

    public private(set) var fingerprints: [String: Fingerprint] = [:]

    public init() {}

    public func isViewed(_ path: String) -> Bool { fingerprints[path] != nil }

    public func mark(_ path: String, as fingerprint: Fingerprint) { fingerprints[path] = fingerprint }

    public func unmark(_ path: String) { fingerprints[path] = nil }

    /// How many of `changes` are marked.
    public func count(in changes: [SessionWorkspace.Review.Change]) -> Int {
        changes.count { isViewed($0.path) }
    }

    /// The first unviewed path after `path`, wrapping round; nil when every other file is viewed.
    public func nextUnviewed(after path: String?, in changes: [SessionWorkspace.Review.Change]) -> String? {
        let start = changes.firstIndex { $0.path == path }.map { $0 + 1 } ?? 0
        return (changes[start...] + changes[..<start]).first { !isViewed($0.path) && $0.path != path }?.path
    }

    /// Drops the marks whose file has changed, or has left `current`.
    public func keep(matching current: [String: Fingerprint]) {
        let kept = Self.surviving(fingerprints, current: current)
        if kept != fingerprints { fingerprints = kept }
    }

    /// The marks that still describe their file.
    public nonisolated static func surviving(
        _ marks: [String: Fingerprint],
        current: [String: Fingerprint]
    ) -> [String: Fingerprint] {
        marks.filter { current[$0.key] == $0.value }
    }
}
