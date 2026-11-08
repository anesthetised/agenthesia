public import Foundation

/// What a clicked link in Markdown should do. Links come from Markdown destinations, so a relative path is a
/// scheme-less URL that no app can open.
public enum LinkTarget: Equatable, Sendable {
    /// A file inside the session's root, relative to the canonical root, for the file pane. A fragment is dropped.
    case file(String)
    /// A web or mail link for the system.
    case external(URL)
    /// Nothing opens: other schemes, files outside the root and links that name no file.
    case ignored

    /// Relative links resolve against the directory `base`; `..` is standardized. Files are accepted only inside
    /// `root`, and not when a symlink leads out of it (ADR-0023).
    public init(_ url: URL, base: URL, root: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            self = .external(url)
        case nil, "file":
            let path = url.path(percentEncoded: false)
            guard !path.isEmpty else {
                self = .ignored
                return
            }
            let file = path.hasPrefix("/") ? URL(filePath: path) : base.appending(path: path)
            let reference = PathReference(path: file.standardizedFileURL.path(percentEncoded: false))
            self = reference.relativePath(in: root).map(LinkTarget.file) ?? .ignored
        default:
            self = .ignored
        }
    }
}
