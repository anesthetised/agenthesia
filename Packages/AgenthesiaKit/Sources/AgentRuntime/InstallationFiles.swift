import Darwin
import Foundation
import Synchronization

/// Filesystem checks shared by publication, launch and removal. The root is an app-owned directory.
enum InstallationFiles {
    /// npm compares prefix with Node's physical cwd. Foundation normalizes /private/var back to /var.
    static func physicalDirectory(_ url: URL) throws -> URL {
        guard let path = realpath(url.path(percentEncoded: false), nil) else {
            throw AgentInstallation.Failure.unownedPath
        }
        defer { free(path) }
        return URL(filePath: String(cString: path), directoryHint: .isDirectory)
    }

    static func component(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".."
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 43, 95].contains($0)
            }
    }

    static func directory(_ url: URL, under root: URL) throws {
        let expected = url.standardizedFileURL.pathComponents
        let resolved = url.resolvingSymlinksInPath().pathComponents
        let base = root.pathComponents
        guard expected == resolved, resolved.starts(with: base), resolved.count >= base.count else {
            throw AgentInstallation.Failure.unownedPath
        }
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw AgentInstallation.Failure.unownedPath
        }
    }

    static func read(_ url: URL, limit: Int = 1_048_576) throws -> Data {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AgentInstallation.Failure.invalidMetadata }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_size <= limit, let data = try handle.read(upToCount: limit + 1), data.count <= limit
        else { throw AgentInstallation.Failure.invalidMetadata }
        return data
    }

    static func executable(_ path: String, in payload: URL, javascript: Bool) throws -> URL {
        try directory(payload, under: payload.standardizedFileURL)
        guard let relative = try? AgentArchive.relativePath(path), !relative.isEmpty else {
            throw AgentInstallation.Failure.invalidExecutable
        }
        let executable = payload.appending(path: relative).resolvingSymlinksInPath()
        let components = executable.pathComponents
        let base = payload.resolvingSymlinksInPath().pathComponents
        guard components.count > base.count, components.starts(with: base),
            (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            javascript
                ? FileManager.default.isReadableFile(atPath: executable.path(percentEncoded: false))
                : FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
        else { throw AgentInstallation.Failure.invalidExecutable }
        return executable
    }
}

/// Advisory locks coordinate app instances; close-on-exec prevents an agent inheriting ownership.
final class InstallationLock: Sendable {
    private let descriptor: Mutex<Int32?>

    init(_ url: URL, shared: Bool = false, create: Bool = false, failure: AgentInstallation.Failure) throws {
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw AgentInstallation.Failure.unownedPath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0
        else { Darwin.close(fd); throw failure }
        descriptor = Mutex(fd)
    }

    func release() {
        descriptor.withLock { descriptor in
            if let descriptor {
                // A concurrent fork can briefly inherit the open-file description before exec closes it.
                // Explicit unlock releases ownership now, even while that inherited reference exists.
                flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            descriptor = nil
        }
    }

    deinit { release() }
}
