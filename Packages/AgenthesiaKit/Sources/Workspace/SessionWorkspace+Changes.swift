public import Foundation

extension SessionWorkspace {
    /// Nil means a non-Git directory. Broken and bare repositories fail instead of changing semantics.
    public static func repositoryRoot(in directory: URL) async throws -> URL? {
        try Task.checkCancellation()
        let root: URL? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try repositoryRootBlocking(in: directory) })
            }
        }
        try Task.checkCancellation()
        return root
    }

    /// Paths relative to the selected directory, including committed (base against HEAD), staged, unstaged and
    /// untracked changes. A nil base lists working changes only. Renames include both the old and new path.
    public static func changedPaths(in directory: URL, baseRevision: String?) async throws -> [String] {
        try Task.checkCancellation()
        let paths: [String] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        // Git itself rejects a broken repository; skip a separate `rev-parse` per refresh.
                        guard hasGitEntry(atOrAbove: directory.resolvingSymlinksInPath().standardizedFileURL) else {
                            throw WorkspaceError(message: "Change tracking requires a Git working checkout.")
                        }
                        let diff = [
                            "diff", "--name-only", "-z", "--relative", "--no-renames", "--no-ext-diff", "--no-textconv",
                        ]
                        var commands = [
                            diff + ["--cached", "HEAD", "--", "."],
                            diff + ["--", "."],
                            ["ls-files", "--others", "--exclude-standard", "-z", "--", "."],
                        ]
                        if let baseRevision {
                            guard [40, 64].contains(baseRevision.utf8.count),
                                baseRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                            else { throw WorkspaceError(message: "The session's initial Git revision is invalid.") }
                            commands.insert(diff + [baseRevision, "HEAD", "--", "."], at: 0)
                        }
                        var paths = Set<String>()
                        for command in commands {
                            let output: Data = try gitOutput(command, in: directory)
                            for bytes in output.split(separator: 0) {
                                // A non-UTF-8 name cannot be opened by relative path; skip it, not the whole list.
                                guard let path = String(data: bytes, encoding: .utf8) else { continue }
                                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
                                else { throw WorkspaceError(message: "Git returned an unsupported file path.") }
                                paths.insert(path)
                            }
                        }
                        return paths.sorted()
                    }
                )
            }
        }
        try Task.checkCancellation()
        return paths
    }

    /// Git metadata can live outside a linked worktree or a selected repository subdirectory.
    public static func watchDirectories(in directory: URL) async throws -> [URL] {
        try Task.checkCancellation()
        let roots: [URL] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
                        var roots = [directory]
                        if try repositoryRootBlocking(in: directory) != nil {
                            for argument in ["--git-dir", "--git-common-dir"] {
                                let path = try gitPath(
                                    ["rev-parse", "--path-format=absolute", argument],
                                    in: directory
                                )
                                roots.append(URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath())
                            }
                        }
                        return Array(Set(roots)).sorted { $0.path < $1.path }
                    }
                )
            }
        }
        try Task.checkCancellation()
        return roots
    }

    private static func repositoryRootBlocking(in directory: URL) throws -> URL? {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WorkspaceError(message: "The session working directory is unavailable.")
        }
        if hasGitEntry(atOrAbove: directory) {
            do {
                return URL(
                    filePath: try gitPath(["rev-parse", "--show-toplevel"], in: directory),
                    directoryHint: .isDirectory
                ).resolvingSymlinksInPath().standardizedFileURL
            } catch { throw brokenRepository(error) }
        }
        if (try? git(["rev-parse", "--is-bare-repository"], in: directory)) == "true" {
            throw WorkspaceError(message: "Change tracking requires a working checkout, not a bare repository.")
        }
        return nil
    }

    private static func gitPath(_ arguments: [String], in directory: URL) throws -> String {
        var data: Data = try gitOutput(arguments, in: directory)
        if data.last == 10 { data.removeLast() }
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
            throw WorkspaceError(message: "Git returned an unsupported directory path.")
        }
        return path
    }
}
