public import Foundation

/// Reads and writes text files, but only inside a set of root directories.
///
/// Paths must be absolute. Symbolic links are resolved before the check, so a link inside a root cannot
/// reach outside it.
public struct ScopedFileAccess: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notAbsolute(String)
        case outsideScope(String)
        case notFound(String)
        case notText(String)
    }

    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// The resolved URL for `path`, if it is absolute and inside one of the roots.
    public func resolve(_ path: String) throws(Failure) -> URL {
        guard path.hasPrefix("/") else { throw .notAbsolute(path) }
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.path(percentEncoded: false).withoutTrailingSlash
        let inside = roots.contains { root in
            let root = root.path(percentEncoded: false).withoutTrailingSlash
            return candidate == root || candidate.hasPrefix(root + "/")
        }
        guard inside else { throw .outsideScope(path) }
        return url
    }

    /// Reads a UTF-8 text file. `line` is 1-based; `limit` is a number of lines.
    public func readText(at path: String, line: Int? = nil, limit: Int? = nil) throws(Failure) -> String {
        let url = try resolve(path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .notFound(path)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText(path) }
        guard line != nil || limit != nil else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max((line ?? 1) - 1, 0)
        guard start < lines.count else { return "" }
        let end = limit.map { min(start + max($0, 0), lines.count) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// Writes a UTF-8 text file, creating intermediate directories.
    public func writeText(_ content: String, to path: String) throws(Failure) {
        let url = try resolve(path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            throw .notFound(path)
        }
    }
}

extension String {
    fileprivate var withoutTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
