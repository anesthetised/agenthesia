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

/// Where a session started from the draft works (ADR-0006, ADR-0040, ADR-0043).
public enum DraftCheckout: Equatable, Sendable {
    /// A Git project: a new worktree from `base` (the upstream, the branch, or the short commit of a detached
    /// `HEAD`), or the project folder itself, where `checkout` (the branch or that commit) is checked out.
    case worktree(from: String, checkout: String)
    case folder

    public static func of(_ directory: URL) async -> DraftCheckout {
        await SessionWorkspace.worktreeBase(of: directory).map { .worktree(from: $0.base, checkout: $0.checkout) }
            ?? .folder
    }

    /// The chip's text; `inProjectFolder` is the draft's choice, which only a Git project offers.
    public func title(inProjectFolder: Bool) -> String {
        switch self {
        case .worktree(let base, _) where !inProjectFolder: "New worktree from \(base)"
        case .worktree, .folder: "Project folder"
        }
    }

    public func help(inProjectFolder: Bool) -> String {
        switch self {
        case .worktree where !inProjectFolder:
            "The session works in a new Git worktree of the committed files. Uncommitted and untracked files are not copied."
        case .worktree(_, let checkout):
            "The agent works in your checkout. Edits land on \(checkout) directly and are not isolated from your own changes."
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
