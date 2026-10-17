public import Foundation
import Workspace

/// A file path as an agent wrote it, with an optional position: `path`, `path:line`, `path:line:column`
/// or `path#Lline`.
public struct PathReference: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// Parses a candidate span: no whitespace, either containing `/` or ending in a file extension.
    /// A leading `./` is dropped. Whether the file exists is for the caller to decide.
    public init?(_ candidate: String) {
        guard !candidate.isEmpty, !candidate.contains("://"),
            !candidate.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value == 0 })
        else { return nil }
        var text = Substring(candidate)
        var line: Int?
        var column: Int?
        if let (rest, number) = Self.number(ending: text, after: "#L") {
            text = rest
            line = number
        } else if let (rest, last) = Self.number(ending: text, after: ":") {
            text = rest
            line = last
            if let (rest, first) = Self.number(ending: text, after: ":") {
                text = rest
                line = first
                column = last
            }
        }
        if text.hasPrefix("./") { text = text.dropFirst(2) }
        let name = text.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        guard !text.isEmpty, text.contains("/") || Self.hasExtension(name) else { return nil }
        self.init(path: String(text), line: line, column: column)
    }

    private static func hasExtension(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name.index(after: dot) != name.endIndex
    }

    /// Splits a trailing number preceded by `marker` off `text`.
    private static func number(ending text: Substring, after marker: String) -> (Substring, Int)? {
        let digits = text.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = Int(String(digits.reversed())) else { return nil }
        let rest = text.dropLast(digits.count)
        guard rest.hasSuffix(marker) else { return nil }
        return (rest.dropLast(marker.count), value)
    }

    /// The path relative to the session's canonical `root`, or nil when it is outside the root, has `..`
    /// components or resolves through a symlink to somewhere else (ADR-0023, ADR-0025).
    public func relativePath(in root: URL) -> String? {
        guard !path.split(separator: "/").contains("..") else { return nil }
        let access = ScopedFileAccess(roots: [root])
        let rootPath = access.roots[0].path(percentEncoded: false)
        let absolute = path.hasPrefix("/") ? path : rootPath + "/" + path
        guard let resolved = try? access.resolve(absolute) else { return nil }
        let relative = resolved.path(percentEncoded: false).dropFirst(rootPath.count).drop { $0 == "/" }
        return relative.isEmpty ? nil : String(relative)
    }
}
