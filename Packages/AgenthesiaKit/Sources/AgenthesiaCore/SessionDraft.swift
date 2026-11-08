public import Foundation
public import Persistence
import Workspace

/// A first message written before its session exists (ADR-0040). `LiveSession` holds it until the session is
/// idle for the first time.
public struct PromptDraft: Equatable, Sendable {
    public var text: String
    public var attachments: [URL]

    public init(text: String = "", attachments: [URL] = []) {
        self.text = text
        self.attachments = attachments
    }

    /// Nothing to send: no attachments and only whitespace.
    public var isEmpty: Bool { attachments.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Where a session started from the draft works (ADR-0006, ADR-0040).
public enum DraftCheckout: Equatable, Sendable {
    /// A Git project: a new worktree from this branch, or the short commit of a detached `HEAD`.
    case worktree(from: String)
    case folder

    public static func of(_ directory: URL) async -> DraftCheckout {
        await SessionWorkspace.worktreeBase(of: directory).map { .worktree(from: $0) } ?? .folder
    }

    public var title: String {
        switch self {
        case .worktree(let base): "New worktree from \(base)"
        case .folder: "Project folder"
        }
    }

    public var help: String {
        switch self {
        case .worktree:
            "The session works in a new Git worktree of the committed files. Uncommitted and untracked files are not copied."
        case .folder: "Not a Git repository: the session works in the folder itself."
        }
    }
}

extension ProjectRecord {
    /// The name of the one project that sessions without a project belong to (ADR-0048).
    public static let scratchName = "No project"

    /// Whether this is the project of sessions without a project, whose root is the scratch root (ADR-0048).
    /// `scratchPath` is `SessionWorkspace.scratchProjectPath(_:)`.
    public func isScratch(scratchPath: String) -> Bool { rootPath == scratchPath }

    /// Most recently used first, by each project's newest session; projects without sessions follow in the given
    /// order. The project of sessions without a project is never offered (ADR-0048).
    public static func recent(
        _ projects: [ProjectRecord],
        history: [SessionRecord],
        scratchPath: String
    ) -> [ProjectRecord] {
        var latest: [UUID: Date] = [:]
        for session in history {
            latest[session.projectID] = max(latest[session.projectID] ?? .distantPast, session.createdAt)
        }
        let projects = projects.filter { !$0.isScratch(scratchPath: scratchPath) }
        return projects.enumerated().sorted { first, second in
            let (a, b) = (latest[first.element.id], latest[second.element.id])
            if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
            return first.offset < second.offset
        }.map(\.element)
    }
}
