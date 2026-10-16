import Darwin
public import Foundation
import Workspace

/// A read-only snapshot of a UTF-8 file in the displayed session's workspace.
public struct SessionFileDocument: Sendable, Equatable {
    public static let maximumBytes = 2 * 1024 * 1024

    public let url: URL
    public let text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidPath, outsideScope, notFound, notText, notRegularFile, tooLarge
        case io(Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidPath: "Choose a local file with a valid path."
            case .outsideScope: "This file is outside the session's working directory."
            case .notFound: "The file no longer exists."
            case .notText: "This file is not supported UTF-8 text."
            case .notRegularFile: "Only regular files can be previewed."
            case .tooLarge: "This file exceeds the 2 MiB preview limit."
            case .io(let code): "The file could not be read (error \(code))."
            }
        }
    }

    /// Loads on a background queue, independently of an agent connection or its lifecycle.
    /// `root` must be the canonical URL captured when the workspace was attached.
    public static func load(root: URL, url: URL) async throws -> SessionFileDocument {
        try Task.checkCancellation()
        guard root.isFileURL, url.isFileURL else { throw Failure.invalidPath }
        let document: SessionFileDocument = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        do {
                            let access = ScopedFileAccess(roots: [root])
                            // Do not broaden a captured root if it was later replaced with an outside symlink.
                            guard access.roots[0].path(percentEncoded: false) == root.path(percentEncoded: false) else {
                                throw Failure.outsideScope
                            }
                            let text = try access.readText(
                                at: url.path(percentEncoded: false),
                                maximumBytes: maximumBytes
                            )
                            guard !text.utf8.contains(0) else { throw Failure.notText }
                            return SessionFileDocument(url: url, text: text)
                        } catch let error as ScopedFileAccess.Failure {
                            switch error {
                            case .notAbsolute, .invalidPath: throw Failure.invalidPath
                            case .outsideScope: throw Failure.outsideScope
                            case .notFound: throw Failure.notFound
                            case .notText: throw Failure.notText
                            case .notRegularFile: throw Failure.notRegularFile
                            case .io(_, EFBIG): throw Failure.tooLarge
                            case .io(_, let code): throw Failure.io(code)
                            }
                        }
                    }
                )
            }
        }
        try Task.checkCancellation()
        return document
    }
}
