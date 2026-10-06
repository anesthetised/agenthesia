import Foundation
public import SwiftTreeSitter
import TreeSitterBash
import TreeSitterGo
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML
import os

/// A programming language with a bundled tree-sitter grammar.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, typescript, tsx, javascript, python, json, markdown, bash, rust, go, yaml

    /// The language for a fenced code block's info string or a name like "py" or "zsh".
    public init?(name: String) {
        let name = name.split(separator: " ").first.map { $0.lowercased() } ?? ""
        guard let language = Self.aliases[name] else { return nil }
        self = language
    }

    /// The language for a file path, by its extension or well-known file name.
    public init?(path: String) {
        let url = URL(filePath: path)
        if let language = Self.fileNames[url.lastPathComponent] {
            self = language
        } else if let language = Self.extensions[url.pathExtension.lowercased()] {
            self = language
        } else {
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .bash: "Shell"
        case .rust: "Rust"
        case .go: "Go"
        case .yaml: "YAML"
        }
    }

    private static let aliases: [String: CodeLanguage] = [
        "swift": .swift,
        "typescript": .typescript, "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "javascript": .javascript, "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "node": .javascript,
        "python": .python, "py": .python, "python3": .python,
        "json": .json, "jsonc": .json, "json5": .json,
        "markdown": .markdown, "md": .markdown,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash, "shellscript": .bash,
        "rust": .rust, "rs": .rust,
        "go": .go, "golang": .go,
        "yaml": .yaml, "yml": .yaml,
    ]

    private static let extensions: [String: CodeLanguage] = [
        "swift": .swift, "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .tsx,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript, "py": .python,
        "pyi": .python, "json": .json, "jsonc": .json, "md": .markdown, "markdown": .markdown, "sh": .bash,
        "bash": .bash, "zsh": .bash, "rs": .rust, "go": .go, "yml": .yaml, "yaml": .yaml,
    ]

    private static let fileNames: [String: CodeLanguage] = [
        ".zshrc": .bash, ".bashrc": .bash, ".bash_profile": .bash, ".profile": .bash, "Package.resolved": .json,
    ]

    // MARK: - Grammar

    /// The grammar and highlight query, loaded once per language. `nil` if the grammar's resources are missing.
    public var configuration: LanguageConfiguration? {
        Self.configurations.withLock { cache in
            if let cached = cache[self] { return cached }
            let configuration = load()
            cache[self] = configuration
            return configuration
        }
    }

    private static let configurations = OSAllocatedUnfairLock(initialState: [CodeLanguage: LanguageConfiguration?]())

    private var grammar: (pointer: OpaquePointer, bundles: [String]) {
        switch self {
        case .swift: (tree_sitter_swift(), ["TreeSitterSwift_TreeSitterSwift"])
        case .typescript:
            (
                tree_sitter_typescript(),
                ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTypeScript"]
            )
        case .tsx:
            (tree_sitter_tsx(), ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTSX"])
        case .javascript: (tree_sitter_javascript(), ["TreeSitterJavaScript_TreeSitterJavaScript"])
        case .python: (tree_sitter_python(), ["TreeSitterPython_TreeSitterPython"])
        case .json: (tree_sitter_json(), ["TreeSitterJSON_TreeSitterJSON"])
        case .markdown: (tree_sitter_markdown(), ["TreeSitterMarkdown_TreeSitterMarkdown"])
        case .bash: (tree_sitter_bash(), ["TreeSitterBash_TreeSitterBash"])
        case .rust: (tree_sitter_rust(), ["TreeSitterRust_TreeSitterRust"])
        case .go: (tree_sitter_go(), ["TreeSitterGo_TreeSitterGo"])
        case .yaml: (tree_sitter_yaml(), ["TreeSitterYAML_TreeSitterYAML"])
        }
    }

    /// Builds the configuration. TypeScript and TSX inherit JavaScript's highlights, so queries are concatenated.
    private func load() -> LanguageConfiguration? {
        let (pointer, bundles) = grammar
        let language = Language(pointer)
        var source = Data()
        for bundle in bundles {
            guard let url = Self.queriesDirectory(inBundleNamed: bundle)?.appending(path: "highlights.scm"),
                let data = try? Data(contentsOf: url)
            else {
                Log.rendering.error(
                    "Missing highlights for \(rawValue, privacy: .public) in \(bundle, privacy: .public)"
                )
                return nil
            }
            source.append(data)
            source.append(0x0A)
        }
        do {
            let query = try Query(language: language, data: source)
            return LanguageConfiguration(language, name: displayName, queries: [.highlights: query])
        } catch {
            Log.rendering.error("Invalid highlights for \(rawValue, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Finds a SwiftPM resource bundle: inside or next to the bundle that contains this code (the app, or the
    /// test bundle), falling back to every loaded bundle.
    static func queriesDirectory(inBundleNamed name: String) -> URL? {
        let bundles = [Bundle(for: BundleToken.self), Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let roots = bundles.flatMap { bundle in
            [bundle.resourceURL, bundle.bundleURL, bundle.bundleURL.deletingLastPathComponent()].compactMap(\.self)
        }
        for root in roots {
            let bundle = root.appending(path: "\(name).bundle")
            for queries in [bundle.appending(path: "queries"), bundle.appending(path: "Contents/Resources/queries")]
            where FileManager.default.fileExists(atPath: queries.path(percentEncoded: false)) {
                return queries
            }
        }
        return nil
    }
}

/// Identifies the bundle that contains this module's code.
private final class BundleToken {}

enum Log {
    static let rendering = Logger(subsystem: "io.github.anesthetised.Agenthesia", category: "Rendering")
}
