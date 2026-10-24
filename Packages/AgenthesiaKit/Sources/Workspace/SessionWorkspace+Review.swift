public import Foundation

extension SessionWorkspace {
    public struct Review: Sendable, Equatable {
        public let baseRevision: String
        public let changes: [Change]

        public struct Change: Sendable, Equatable, Identifiable {
            public enum Status: String, Sendable {
                case added = "Added", deleted = "Deleted", modified = "Modified", renamed = "Renamed", untracked =
                    "Untracked", typeChanged = "Type changed"
            }
            public let path: String
            public let previousPath: String?
            public let status: Status
            public var id: String { path }
        }
    }

    public enum ReviewFailure: Error { case tooLarge, notRegularFile }

    /// The net working-tree changes from the base branch's merge base, or the saved initial revision.
    /// Legacy sessions without either compare with HEAD. Paths stay relative to the selected directory.
    public static func review(in directory: URL, baseBranch: String?, baseRevision: String?) async throws -> Review {
        try Task.checkCancellation()
        let review: Review = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let revision: String
                        if let baseBranch {
                            let ref = "refs/heads/\(baseBranch)"
                            guard (try? git(["rev-parse", "--verify", "--end-of-options", ref], in: directory)) != nil
                            else {
                                throw WorkspaceError(message: "The base branch “\(baseBranch)” no longer exists.")
                            }
                            revision = try git(["merge-base", ref, "HEAD"], in: directory)
                        } else {
                            revision = try git(
                                ["rev-parse", "--verify", "--end-of-options", "\(baseRevision ?? "HEAD")^{commit}"],
                                in: directory
                            )
                        }
                        let output: Data = try gitOutput(
                            [
                                "diff", "--name-status", "-z", "-M", "--relative", "--no-ext-diff", "--no-textconv",
                                revision, "--", ".",
                            ],
                            in: directory
                        )
                        let fields = output.split(separator: 0)
                        var changes: [Review.Change] = []
                        var index = 0
                        while index < fields.count {
                            let status = String(decoding: fields[index], as: UTF8.self).first
                            let renamed = status == "R"
                            let count = renamed ? 3 : 2
                            guard index + count <= fields.count else {
                                throw WorkspaceError(message: "Git returned an incomplete change list.")
                            }
                            defer { index += count }
                            guard let path = reviewPath(fields[index + count - 1]) else { continue }
                            let previous = renamed ? reviewPath(fields[index + 1]) : nil
                            if renamed && previous == nil { continue }
                            let kind: Review.Change.Status
                            switch status {
                            case "A": kind = .added
                            case "D": kind = .deleted
                            case "R": kind = .renamed
                            case "T": kind = .typeChanged
                            default: kind = .modified
                            }
                            changes.append(.init(path: path, previousPath: previous, status: kind))
                        }
                        let untracked: Data = try gitOutput(
                            ["ls-files", "--others", "--exclude-standard", "-z", "--", "."],
                            in: directory
                        )
                        for field in untracked.split(separator: 0) {
                            if let path = reviewPath(field) {
                                changes.append(.init(path: path, previousPath: nil, status: .untracked))
                            }
                        }
                        return Review(baseRevision: revision, changes: changes.sorted { $0.path < $1.path })
                    }
                )
            }
        }
        try Task.checkCancellation()
        return review
    }

    /// Reads one immutable Git blob after checking its size; never materializes an oversized object.
    public static func reviewContents(
        in directory: URL,
        path: String,
        revision: String,
        maximumBytes: Int
    ) async throws -> Data {
        guard reviewPath(Data(path.utf8)) != nil,
            [40, 64].contains(revision.utf8.count),
            revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw WorkspaceError(message: "The review file path or revision is invalid.") }
        let prefix = try await git(["rev-parse", "--show-prefix"], in: directory)
        let object = try await git(["rev-parse", "--verify", "\(revision):\(prefix)\(path)"], in: directory)
        guard try await git(["cat-file", "-t", object], in: directory) == "blob" else {
            throw ReviewFailure.notRegularFile
        }
        guard let size = Int(try await git(["cat-file", "-s", object], in: directory)), size <= maximumBytes else {
            throw ReviewFailure.tooLarge
        }
        return try await gitOutput(["cat-file", "blob", object], in: directory)
    }

    private static func reviewPath(_ data: Data.SubSequence) -> String? {
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty, !path.hasPrefix("/"),
            !path.utf8.contains(0), !path.split(separator: "/").contains("..")
        else { return nil }
        return path
    }
}
