public import Foundation

/// Added and removed line counts of the changed files of a session.
public struct ChangeStats: Sendable, Equatable {
    public struct Lines: Sendable, Equatable {
        public var added: Int
        public var removed: Int

        public init(added: Int, removed: Int) {
            self.added = added
            self.removed = removed
        }
    }

    /// Text files by path. A path whose contents equal the base has no entry.
    public var files: [String: Lines]
    /// Paths that have no line counts (binary files and entries that are not regular files).
    public var binary: Set<String>

    public init(files: [String: Lines] = [:], binary: Set<String> = []) {
        self.files = files
        self.binary = binary
    }

    /// Binary files are left out.
    public var total: Lines {
        files.values.reduce(Lines(added: 0, removed: 0)) {
            Lines(added: $0.added + $1.added, removed: $0.removed + $1.removed)
        }
    }
}

extension SessionWorkspace {
    /// Line counts of the net change from the base (or from `HEAD` when it is nil) to the working tree, relative
    /// to the selected directory. Renames count as a deletion plus an addition, as in `changedPaths`. Untracked
    /// text files count all their lines as added.
    public static func changeStats(in directory: URL, baseRevision: String?) async throws -> ChangeStats {
        try Task.checkCancellation()
        let stats: ChangeStats = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        guard hasGitEntry(atOrAbove: directory.resolvingSymlinksInPath().standardizedFileURL) else {
                            throw WorkspaceError(message: "Change tracking requires a Git working checkout.")
                        }
                        if let baseRevision { try validateRevision(baseRevision) }
                        var stats = ChangeStats()
                        let numstat: Data = try gitOutput(
                            ["diff", "--numstat", "-z", "--relative", "--no-renames", "--no-ext-diff", "--no-textconv"]
                                + [baseRevision ?? "HEAD", "--", "."],
                            in: directory
                        )
                        for record in numstat.split(separator: 0) {
                            // `added<TAB>removed<TAB>path`; binary files print `-` for both counts.
                            let fields = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2)
                            guard fields.count == 3, let path = String(data: fields[2], encoding: .utf8) else {
                                continue
                            }
                            if let added = Int(String(decoding: fields[0], as: UTF8.self)),
                                let removed = Int(String(decoding: fields[1], as: UTF8.self))
                            {
                                stats.files[path] = ChangeStats.Lines(added: added, removed: removed)
                            } else {
                                stats.binary.insert(path)
                            }
                        }
                        let untracked: Data = try gitOutput(
                            ["ls-files", "--others", "--exclude-standard", "-z", "--", "."],
                            in: directory
                        )
                        for bytes in untracked.split(separator: 0) {
                            guard let path = String(data: bytes, encoding: .utf8), !path.hasPrefix("/"),
                                !path.split(separator: "/").contains("..")
                            else { continue }
                            if let lines = untrackedLineCount(at: directory.appending(path: path)) {
                                if lines > 0 { stats.files[path] = ChangeStats.Lines(added: lines, removed: 0) }
                            } else {
                                stats.binary.insert(path)
                            }
                        }
                        return stats
                    }
                )
            }
        }
        try Task.checkCancellation()
        return stats
    }

    /// Nil for a binary (a NUL byte in the first 8000 bytes, as Git decides) or unreadable file.
    private static func untrackedLineCount(at url: URL) -> Int? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        let newlines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return newlines + (data.last.map { $0 != 10 } == true ? 1 : 0)
    }
}
