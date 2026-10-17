import ACP
import AgenthesiaCore
public import AppKit
import Rendering

/// A transcript link to a file in the displayed session. It uses a private scheme so that the transcript can
/// intercept the click and no other app receives it (ADR-0025).
struct PathLink: Equatable {
    static let scheme = "agenthesia-path"

    /// Relative to the session's working directory.
    var path: String
    var line: Int?

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        components.path = "/" + path
        components.queryItems = line.map { [URLQueryItem(name: "line", value: String($0))] }
        return components.url
    }

    init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.path.hasPrefix("/"), components.path.count > 1
        else { return nil }
        path = String(components.path.dropFirst())
        line = components.queryItems?.first { $0.name == "line" }?.value.flatMap { Int($0) }
    }

    /// Whether `url` belongs to the transcript, even when it is malformed and leads nowhere.
    static func claims(_ url: URL) -> Bool { url.scheme == scheme }

    /// What a tool call displays as a path: its locations with their line, then each diff's path.
    /// Paths that do not resolve inside `root` are left out.
    static func targets(of tool: ACP.ToolCall, root: URL) -> [(display: String, link: PathLink)] {
        var targets: [(String, PathLink)] = []
        for location in tool.locations ?? [] {
            guard let path = PathReference(path: location.path).relativePath(in: root) else { continue }
            targets.append(
                (location.path + (location.line.map { ":\($0)" } ?? ""), PathLink(path: path, line: location.line))
            )
        }
        for case .diff(let diff) in tool.content ?? [] {
            guard let path = PathReference(path: diff.path).relativePath(in: root) else { continue }
            targets.append((diff.path, PathLink(path: path)))
        }
        return targets
    }

    /// Links the inline code that shows each target, in order. The first match with the code background after the
    /// previous one wins, so a title or prose with the same words stays plain.
    static func apply(_ targets: [(display: String, link: PathLink)], to text: NSMutableAttributedString) {
        let string = text.string as NSString
        var start = 0
        for (display, link) in targets {
            guard let url = link.url else { continue }
            var search = NSRange(location: start, length: string.length - start)
            while search.length > 0 {
                let found = string.range(of: display, range: search)
                guard found.location != NSNotFound else { break }
                if text.attribute(.backgroundColor, at: found.location, effectiveRange: nil) != nil {
                    text.addAttributes([.link: url, .foregroundColor: Theme.standard.linkColor], range: found)
                    start = NSMaxRange(found)
                    break
                }
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: string.length - next)
            }
        }
    }
}

/// The displayed session's file index, against which inline code in agent text links (ADR-0025). Public for
/// `transcript-bench`.
public struct TranscriptPathIndex: Sendable {
    /// Relative to the session's working directory.
    public var paths: Set<String>
    /// Prefixes under which absolute paths are looked up: the canonical root and the directory the agent was given.
    public var roots: [String]
    /// Changes with every published index, so the transcript compares it instead of the paths.
    public var revision: Int

    // Nonisolated so that a nonisolated owner, such as a test double, can create an empty index as a default
    // value; Swift 6.2 rejects a main-actor default there.
    public nonisolated init(paths: Set<String> = [], roots: [String] = [], revision: Int = 0) {
        self.paths = paths
        self.roots = roots
        self.revision = revision
    }

    /// Links inline code that names an indexed file, without the file system. Returns `text` itself when nothing
    /// links, and a signature of the links, so a row is rebuilt only when its links change.
    public func linkingInlineCode(in text: NSAttributedString) -> (text: NSAttributedString, signature: Int) {
        guard !paths.isEmpty, text.length > 0 else { return (text, 0) }
        let string = text.string as NSString
        var linked: NSMutableAttributedString?
        var hasher = Hasher()
        text.enumerateAttribute(.inlineCode, in: NSRange(0..<text.length)) { value, range, _ in
            guard value != nil, text.attribute(.link, at: range.location, effectiveRange: nil) == nil,
                let reference = PathReference(string.substring(with: range)),
                let path = reference.indexedPath(in: paths, roots: roots),
                let url = PathLink(path: path, line: reference.line).url
            else { return }
            let target = linked ?? NSMutableAttributedString(attributedString: text)
            target.addAttributes([.link: url, .foregroundColor: Theme.standard.linkColor], range: range)
            linked = target
            hasher.combine(range.location)
            hasher.combine(url)
        }
        guard let linked else { return (text, 0) }
        return (linked, hasher.finalize())
    }
}
