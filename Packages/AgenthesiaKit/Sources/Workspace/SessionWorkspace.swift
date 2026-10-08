public import Foundation

/// A session's working directory. Worktrees are deliberately retained on close and failed startup.
public struct SessionWorkspace: Sendable {
    public let projectDirectory: URL
    public let workingDirectory: URL

    public static func prepare(
        directory: URL,
        id: UUID,
        worktreesRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agenthesia/worktrees")
    ) async throws -> SessionWorkspace {
        try await Task.detached {
            let directory = directory.resolvingSymlinksInPath().standardizedFileURL
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw WorkspaceError(message: "Choose an existing directory.")
            }
            // A .git entry is also present in linked worktrees and submodules. A broken repository
            // must fail rather than silently fall back to running in the user's checkout.
            var ancestor = directory
            var repository = false
            while true {
                if FileManager.default.fileExists(atPath: ancestor.appending(path: ".git").path) {
                    repository = true
                    break
                }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
            guard repository else {
                // Bare repositories cannot supply a working directory.
                if (try? git(["rev-parse", "--is-bare-repository"], in: directory)) == "true" {
                    throw WorkspaceError(message: "Choose a working checkout, not a bare repository.")
                }
                return SessionWorkspace(projectDirectory: directory, workingDirectory: directory)
            }
            let root = URL(
                filePath: try git(["rev-parse", "--show-toplevel"], in: directory),
                directoryHint: .isDirectory
            ).resolvingSymlinksInPath()
            let slug = id.uuidString.lowercased()
            let destination = worktreesRoot.appending(path: root.lastPathComponent).appending(path: slug)
                .resolvingSymlinksInPath().standardizedFileURL
            guard root.path != "/", !destination.path.hasPrefix(root.path + "/") else {
                throw WorkspaceError(message: "The worktree location must be outside the selected repository.")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try git(["worktree", "add", "--quiet", "-b", "agenthesia/\(slug)", destination.path, "HEAD"], in: root)
            return SessionWorkspace(projectDirectory: root, workingDirectory: destination)
        }.value
    }

    struct WorkspaceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs off the main actor. One combined pipe is drained before waiting, avoiding pipe deadlock.
    @discardableResult static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard process.terminationStatus == 0 else { throw WorkspaceError(message: "Git: \(text)") }
        return text
    }
}
