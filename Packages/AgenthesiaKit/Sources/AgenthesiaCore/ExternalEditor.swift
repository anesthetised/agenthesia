public import Foundation

/// An editor Open in Editor can hand a file to, identified by its bundle identifier (ADR-0025).
public struct ExternalEditor: Equatable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let name: String
    /// URL scheme of the form `<scheme>://file/<path>:<line>`; nil when the editor has no confirmed way
    /// to open a file at a line.
    let lineScheme: String?

    public var id: String { bundleIdentifier }
    public var supportsLine: Bool { lineScheme != nil }

    public static let all = [
        ExternalEditor(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code", lineScheme: "vscode"),
        ExternalEditor(bundleIdentifier: "com.todesktop.230313mzl4w4u92", name: "Cursor", lineScheme: "cursor"),
        ExternalEditor(bundleIdentifier: "dev.zed.Zed", name: "Zed", lineScheme: "zed"),
        ExternalEditor(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", lineScheme: nil),
    ]

    public static func named(_ bundleIdentifier: String) -> ExternalEditor? {
        all.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// The URL that opens `path` (relative to `root`) at `line`, or nil when the editor has no line scheme.
    public func url(opening path: String, line: Int?, in root: URL) -> URL? {
        guard let lineScheme else { return nil }
        let absolute = root.path(percentEncoded: false) + "/" + path
        guard let encoded = absolute.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else { return nil }
        return URL(string: "\(lineScheme)://file\(encoded)" + (line.map { ":\($0)" } ?? ""))
    }

    private static let unreserved = CharacterSet(charactersIn: "/-._~")
        .union(CharacterSet(charactersIn: "a"..."z")).union(CharacterSet(charactersIn: "A"..."Z"))
        .union(CharacterSet(charactersIn: "0"..."9"))
}
