public import Foundation
import Observation
public import Persistence
public import Workspace

/// A window's read-only review. Reads are lazy, and refreshes keep a still-differing file selected.
///
/// A refresh reads the selected file before replacing anything (ADR-0041): an equal document changes nothing, and
/// while the view has text selected in the shown diff of that file, a change is held until `showLatest()` or the
/// selection ends.
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
    /// The diff view has text selected; only the view knows what. Clearing it applies a held change.
    public var hasSelection = false {
        didSet { if !hasSelection { showLatest() } }
    }
    /// What a refresh read while a selection held the shown diff: `File changed · Show latest`.
    public var isHolding: Bool { held != nil }
    private var held: (document: Document?, error: String?)?
    /// A refresh can change contents without changing the selected path or base revision.
    public private(set) var revision = UUID()
    private let root: URL
    private let baseRevision: String?
    private var refreshToken = UUID()
    private var readToken = UUID()

    public struct Document: Equatable, Sendable {
        public let path: String
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
            // A held diff keeps its path while the file is gone from the list; Show latest moves on.
            if !changes.contains(where: { $0.path == selectedPath }), !holdsShownDocument {
                selectedPath = changes.first?.path
            }
            revision = UUID()
        } catch {
            guard refreshToken == token, !Task.isCancelled else { return }
            snapshot = nil
            selectedPath = nil
            document = nil
            held = nil
            self.error = error.localizedDescription
            revision = UUID()
        }
    }

    public func loadSelection() async {
        let token = UUID()
        readToken = token
        guard let snapshot, let change = changes.first(where: { $0.path == selectedPath }) else {
            show(nil, error: nil)
            return
        }
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
            show(Document(path: change.path, old: old, new: new), error: nil)
        } catch {
            guard readToken == token, !Task.isCancelled, selectedPath == change.path, self.revision == revision else {
                return
            }
            let message =
                switch error {
                case SessionWorkspace.ReviewFailure.tooLarge: SessionFileDocument.Failure.tooLarge.localizedDescription
                case SessionWorkspace.ReviewFailure.notRegularFile:
                    SessionFileDocument.Failure.notRegularFile.localizedDescription
                default: error.localizedDescription
                }
            show(nil, error: message)
        }
    }

    /// Applies a held change; the selected file moves on if the held one left the list.
    public func showLatest() {
        guard let held else { return }
        self.held = nil
        document = held.document
        documentError = held.error
        if !changes.contains(where: { $0.path == selectedPath }) { selectedPath = changes.first?.path }
    }

    /// A selection is in the shown diff of the selected file.
    private var holdsShownDocument: Bool { hasSelection && document != nil && document?.path == selectedPath }

    /// Replaces what is shown with what was read, unless it is equal or a selection holds the shown diff.
    private func show(_ document: Document?, error: String?) {
        guard document != self.document || error != documentError else {
            // Even an equal assignment would invalidate the views that read it.
            if held != nil { held = nil }
            return
        }
        if holdsShownDocument {
            held = (document, error)
        } else {
            held = nil
            self.document = document
            documentError = error
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
