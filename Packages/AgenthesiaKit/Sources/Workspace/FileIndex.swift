public import Foundation
import Synchronization

/// A snapshot of file paths relative to a session's selected working directory.
public struct FileIndex: Sendable {
    public let paths: [String]
    private let candidates: [(path: String, folded: String, basename: String)]

    init(paths: [String]) {
        self.paths = Set(paths).sorted()
        candidates = self.paths.map {
            ($0, $0.lowercased(), ($0 as NSString).lastPathComponent.lowercased())
        }
    }

    /// Git contributes tracked and untracked nonignored files; ordinary directories are walked.
    /// Callers that already know whether `directory` is in a repository pass it to skip that lookup.
    /// Unreadable subdirectories and non-UTF-8 names are skipped; an unreadable root fails.
    public static func load(in directory: URL, isGitRepository: Bool? = nil) async throws -> FileIndex {
        try Task.checkCancellation()
        let directory = directory.standardizedFileURL
        let data: Data?
        let git: Bool
        if let isGitRepository {
            git = isGitRepository
        } else {
            git = try await SessionWorkspace.repositoryRoot(in: directory) != nil
        }
        if git {
            data = try await SessionWorkspace.gitOutput(
                ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."],
                in: directory
            )
        } else {
            data = nil
        }
        // Directory enumeration and metadata lookups must not block a cooperative executor.
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            // Enumeration uses physical paths (e.g. /private/var); use the same spelling for the root.
                            let directory = ScopedFileAccess(roots: [directory]).roots[0]
                            let check: @Sendable () throws -> Void = {
                                if cancelled.withLock({ $0 }) { throw CancellationError() }
                            }
                            try check()
                            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                                throw SessionWorkspace.WorkspaceError(message: "Choose an existing directory.")
                            }
                            var paths: [String] = []
                            if let data {
                                for bytes in data.split(separator: 0) {
                                    try check()
                                    guard let path = String(data: bytes, encoding: .utf8) else { continue }
                                    var isDirectory: ObjCBool = false
                                    if FileManager.default.fileExists(
                                        atPath: directory.appending(path: path).path,
                                        isDirectory: &isDirectory
                                    ), !isDirectory.boolValue {
                                        paths.append(path)
                                    }
                                }
                            } else {
                                // Fail for an unreadable root; the enumerator skips unreadable subtrees.
                                _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                                guard
                                    let enumerator = FileManager.default.enumerator(
                                        at: directory,
                                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                        errorHandler: { _, _ in true }
                                    )
                                else {
                                    throw SessionWorkspace.WorkspaceError(
                                        message: "Cannot enumerate the working directory."
                                    )
                                }
                                for case let url as URL in enumerator {
                                    try check()
                                    if url.lastPathComponent == ".git" {
                                        enumerator.skipDescendants()
                                        continue
                                    }
                                    // An entry can disappear during the walk.
                                    guard
                                        let values = try? url.resourceValues(forKeys: [
                                            .isRegularFileKey, .isSymbolicLinkKey,
                                        ])
                                    else { continue }
                                    if values.isSymbolicLink == true {
                                        enumerator.skipDescendants()
                                    } else if values.isRegularFile == true {
                                        let prefix =
                                            directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
                                        paths.append(String(url.path.dropFirst(prefix.count)))
                                    }
                                }
                            }
                            try check()
                            return FileIndex(paths: paths)
                        }
                    )
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Case-insensitive subsequence matching, preferring basename matches over directory matches.
    /// Run away from the main actor; cancellation is checked while scanning the snapshot.
    public func matching(_ query: String, limit: Int = 100) throws -> [String] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let folded = query.lowercased()
        guard !folded.isEmpty else { return Array(paths.prefix(limit)) }
        let needle = Array(folded)
        var best: [(category: Int, gaps: Int, length: Int, path: String)] = []
        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            let category: Int
            let gaps: Int
            if candidate.basename == folded {
                category = 0; gaps = 0
            } else if candidate.basename.hasPrefix(folded) {
                category = 1; gaps = 0
            } else if candidate.basename.contains(folded) {
                category = 2; gaps = 0
            } else if let span = Self.subsequence(needle, in: candidate.basename) {
                category = 3; gaps = span
            } else if let span = Self.subsequence(needle, in: candidate.folded) {
                category = 4; gaps = span
            } else {
                continue
            }
            let rank = (category, gaps, candidate.path.count, candidate.path)
            // Keep only the requested best matches; the palette asks for 100.
            if let position = best.firstIndex(where: { rank < $0 }) {
                best.insert(rank, at: position)
                if best.count > limit { best.removeLast() }
            } else if best.count < limit {
                best.append(rank)
            }
        }
        try Task.checkCancellation()
        return best.map(\.path)
    }

    private static func subsequence(_ needle: [Character], in text: String) -> Int? {
        var matched = 0
        var start = 0
        for (offset, character) in text.enumerated() where character == needle[matched] {
            if matched == 0 { start = offset }
            matched += 1
            if matched == needle.count { return offset - start + 1 - needle.count }
        }
        return nil
    }
}
