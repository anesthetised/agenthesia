import Darwin
public import Foundation

/// Reads and writes text files, but only inside a set of root directories.
///
/// Paths must be absolute. Resolve links within the roots, then refuse any newly substituted symlink
/// when opening the file or its parent. This is a path policy, not a sandbox for other processes.
public struct ScopedFileAccess: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notAbsolute(String)
        case outsideScope(String)
        case notFound(String)
        case notText(String)
        case invalidPath(String)
        case notRegularFile(String)
        case io(String, Int32)
    }

    public let roots: [URL]
    // Test seam for substituting a path between resolution and opening it.
    var beforeAccess: (@Sendable () -> Void)?

    public init(roots: [URL]) {
        self.roots = roots.map(Self.canonicalURL)
    }

    /// The resolved URL for `path`, if it is absolute and inside one of the roots.
    public func resolve(_ path: String) throws(Failure) -> URL {
        guard !path.utf8.contains(0) else { throw .invalidPath(path) }
        guard path.hasPrefix("/") else { throw .notAbsolute(path) }
        let url = Self.canonicalURL(URL(filePath: path))
        let candidate = url.path(percentEncoded: false).withoutTrailingSlash
        let inside = roots.contains { root in
            let root = root.path(percentEncoded: false).withoutTrailingSlash
            return root == "/" || candidate == root || candidate.hasPrefix(root + "/")
        }
        guard inside else { throw .outsideScope(path) }
        return url
    }

    /// Reads a UTF-8 text file. `line` is 1-based; `limit` is a number of lines.
    public func readText(at path: String, line: Int? = nil, limit: Int? = nil) throws(Failure) -> String {
        let url = try resolve(path)
        beforeAccess?()
        // O_NONBLOCK prevents a substituted FIFO from blocking before fstat can reject it.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure(path) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(path) }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw .io(path, Self.posixCode(from: error))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText(path) }
        guard line != nil || limit != nil else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = (line ?? 1) <= 1 ? 0 : (line ?? 1) - 1
        guard start < lines.count else { return "" }
        let end = limit.map { start + min(max($0, 0), lines.count - start) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// Writes a UTF-8 text file, creating intermediate directories.
    public func writeText(_ content: String, to path: String) throws(Failure) {
        let url = try resolve(path)
        beforeAccess?()
        let parent = try openParent(of: url, original: path)
        defer { Darwin.close(parent) }
        let name = url.lastPathComponent
        var info = stat()
        let exists = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile(path) }
        } else if errno != ENOENT {
            throw failure(path)
        }
        // Replace the directory entry atomically; never follow a substituted final symlink or write
        // through a hard link. Keep the parent's descriptor throughout creation and rename.
        let temporary = ".agenthesia-\(UUID().uuidString)"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw failure(path) }
        defer {
            Darwin.close(descriptor)
            unlinkat(parent, temporary, 0)
        }
        if exists, fchmod(descriptor, info.st_mode & 0o777) != 0 { throw failure(path) }
        do {
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data(content.utf8))
        } catch {
            throw .io(path, Self.posixCode(from: error))
        }
        guard renameat(parent, temporary, parent, name) == 0 else { throw failure(path) }
    }

    private func openParent(of url: URL, original: String) throws(Failure) -> Int32 {
        let candidate = url.path(percentEncoded: false)
        guard
            let root = roots.filter({
                let path = $0.path(percentEncoded: false).withoutTrailingSlash
                return path == "/" || candidate == path || candidate.hasPrefix(path + "/")
            }).max(by: { $0.path.count < $1.path.count })
        else { throw .outsideScope(original) }
        let rootPath = root.path(percentEncoded: false).withoutTrailingSlash
        guard candidate != rootPath else { throw .notRegularFile(original) }
        var directory = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw failure(original) }
        do throws(Failure) {
            let components = candidate.dropFirst(rootPath.count).split(separator: "/").dropLast()
            for component in components {
                let name = String(component)
                var child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT {
                    guard mkdirat(directory, name, 0o777) == 0 || errno == EEXIST else { throw failure(original) }
                    child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw failure(original) }
                Darwin.close(directory)
                directory = child
            }
            return directory
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private func failure(_ path: String) -> Failure {
        errno == ENOENT ? .notFound(path) : .io(path, errno)
    }

    static func posixCode(from error: any Error) -> Int32 {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(exactly: error.code) ?? EIO }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return posixCode(from: underlying)
        }
        // FileHandle may omit its underlying POSIX error. A Cocoa code is never an errno value.
        return EIO
    }

    private static func canonicalURL(_ url: URL) -> URL {
        // Foundation keeps aliases such as /var in resolved URLs on macOS. O_NOFOLLOW_ANY needs
        // the kernel's spelling (/private/var). Resolve the existing prefix even for a new file.
        var prefix = url.standardizedFileURL.resolvingSymlinksInPath()
        var suffix: [String] = []
        while true {
            if let resolved = realpath(prefix.path, nil) {
                var result = URL(filePath: String(cString: resolved))
                free(resolved)
                for component in suffix.reversed() { result.append(path: component) }
                return result
            }
            let parent = prefix.deletingLastPathComponent()
            guard parent.path != prefix.path else { return prefix }
            suffix.append(prefix.lastPathComponent)
            prefix = parent
        }
    }
}

extension String {
    fileprivate var withoutTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
