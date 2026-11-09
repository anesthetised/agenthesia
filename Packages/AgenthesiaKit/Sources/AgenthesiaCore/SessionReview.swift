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
    /// The session works in the project folder (ADR-0043): the review compares with its start, not the merge base
    /// with its branch, which is the checkout itself.
    public let inProjectFolder: Bool
    private var snapshot: SessionWorkspace.Review?
    public var changes: [SessionWorkspace.Review.Change] { snapshot?.changes ?? [] }
    /// Line counts against the review's own merge base; a path without an entry has none to show.
    public private(set) var stats = ChangeStats()
    /// Shared with the window, so the marks outlive this review (ADR-0041).
    public let viewed: ViewedMarks
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
    public init(
        session: SessionRecord,
        root: URL,
        viewed: ViewedMarks = ViewedMarks(),
        inProjectFolder: Bool = false
    ) {
        id = session.id
        self.viewed = viewed
        self.root = root
        self.inProjectFolder = inProjectFolder
        baseBranch = inProjectFolder ? nil : session.baseBranch
        baseRevision = session.baseRevision
    }

    /// What the review compares with, for its header.
    public var title: String {
        if inProjectFolder { return "Changes since the session started" }
        return baseBranch.map { "Changes against \($0)" } ?? "Session changes"
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
            // Counts are decoration: a failure to count must not hide the review.
            let counted = (try? await SessionWorkspace.changeStats(in: root, baseRevision: updated.baseRevision))
            let marked = updated.changes.filter { viewed.isViewed($0.path) }
            let root = root
            let current = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: Dictionary(
                            uniqueKeysWithValues: marked.map { ($0.path, ViewedMarks.Fingerprint.read($0, in: root)) }
                        )
                    )
                }
            }
            try await checkRoot()
            guard refreshToken == token else { return }
            snapshot = updated
            stats = counted ?? ChangeStats()
            viewed.keep(matching: current)
            error = nil
            // A held diff keeps its path while the file is gone from the list; Show latest moves on.
            if !changes.contains(where: { $0.path == selectedPath }), !holdsShownDocument {
                selectedPath = changes.first?.path
            }
            revision = UUID()
        } catch {
            guard refreshToken == token, !Task.isCancelled else { return }
            snapshot = nil
            stats = ChangeStats()
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

    public var viewedCount: Int { viewed.count(in: changes) }
    /// The footer's `2 of 5 viewed`.
    public var viewedSummary: String { "\(viewedCount) of \(changes.count) viewed" }

    /// Marks or unmarks a file, remembering what it looks like now.
    public func toggleViewed(_ path: String) {
        guard let change = changes.first(where: { $0.path == path }) else { return }
        if viewed.isViewed(path) {
            viewed.unmark(path)
        } else {
            viewed.mark(path, as: .read(change, in: root))
        }
    }

    /// ⌥⌘V: marks the selected file and selects the next unviewed one, if any.
    public func markSelectedViewedAndAdvance() {
        guard let path = selectedPath, changes.contains(where: { $0.path == path }) else { return }
        if !viewed.isViewed(path) { toggleViewed(path) }
        if let next = viewed.nextUnviewed(after: path, in: changes) { selectedPath = next }
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
