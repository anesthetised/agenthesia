import ACP
import AgenthesiaCore
import AppKit
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
