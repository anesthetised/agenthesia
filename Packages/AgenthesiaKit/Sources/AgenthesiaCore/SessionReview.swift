public import Foundation
import Observation
public import Persistence
public import Workspace

/// A window's read-only review. Reads are lazy, and refreshes keep a still-differing file selected.
@MainActor @Observable public final class SessionReview: Identifiable {
    public let id: UUID
    public let baseBranch: String?
    private var snapshot: SessionWorkspace.Review?
    public var changes: [SessionWorkspace.Review.Change] { snapshot?.changes ?? [] }
    public var selectedPath: String?
    public private(set) var document: Document?
    public private(set) var error: String?
    public private(set) var documentError: String?
    public private(set) var isLoading = false
    /// A refresh can change contents without changing the selected path or base revision.
    public private(set) var revision = UUID()
    private let root: URL
    private let baseRevision: String?
    private var refreshToken = UUID()
    private var readToken = UUID()

    public struct Document: Equatable, Sendable {
        public let old: String?
        public let new: String
    }

    /// `root` is the canonical directory captured by `SessionFiles` when the session was attached.
    public init(session: SessionRecord, root: URL) {
        id = session.id
        self.root = root
        baseBranch = session.baseBranch
        baseRevision = session.baseRevision
    }

    public func refresh() async {
        let token = UUID()
        refreshToken = token
        isLoading = snapshot == nil
        defer { if refreshToken == token { isLoading = false } }
        do {
            try await checkRoot()
            let updated = try await SessionWorkspace.review(
                in: root,
                baseBranch: baseBranch,
                baseRevision: baseRevision
            )
            try await checkRoot()
            guard refreshToken == token else { return }
            snapshot = updated
            error = nil
            if !changes.contains(where: { $0.path == selectedPath }) { selectedPath = changes.first?.path }
            revision = UUID()
        } catch {
            guard refreshToken == token, !Task.isCancelled else { return }
            snapshot = nil
            selectedPath = nil
            document = nil
            self.error = error.localizedDescription
            revision = UUID()
        }
    }

    public func loadSelection() async {
        let token = UUID()
        readToken = token
        document = nil
        documentError = nil
        guard let snapshot, let change = changes.first(where: { $0.path == selectedPath }) else { return }
        let revision = revision
        do {
            try await checkRoot()
            let old: String?
            if change.status == .added || change.status == .untracked {
                old = nil
            } else {
                let data = try await SessionWorkspace.reviewContents(
                    in: root,
                    path: change.previousPath ?? change.path,
                    revision: snapshot.baseRevision,
                    maximumBytes: SessionFileDocument.maximumBytes
                )
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                    throw SessionFileDocument.Failure.notText
                }
                old = text
            }
            let new: String
            if change.status == .deleted {
                new = ""
            } else {
                new = try await SessionFileDocument.load(root: root, url: root.appending(path: change.path)).text
            }
            try await checkRoot()
            guard readToken == token, selectedPath == change.path, self.revision == revision else { return }
            document = Document(old: old, new: new)
        } catch {
            guard readToken == token, !Task.isCancelled, selectedPath == change.path, self.revision == revision else {
                return
            }
            switch error {
            case SessionWorkspace.ReviewFailure.tooLarge:
                documentError = SessionFileDocument.Failure.tooLarge.localizedDescription
            case SessionWorkspace.ReviewFailure.notRegularFile:
                documentError = SessionFileDocument.Failure.notRegularFile.localizedDescription
            default: documentError = error.localizedDescription
            }
        }
    }

    private func checkRoot() async throws {
        try Task.checkCancellation()
        let root = root
        let unchanged = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScopedFileAccess.isCanonical(root))
            }
        }
        try Task.checkCancellation()
        guard unchanged else { throw SessionFileDocument.Failure.outsideScope }
    }
}
