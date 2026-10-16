public import Foundation
import Observation
public import Persistence
import Workspace

/// Current files of the displayed session, independent of its agent connection and event log.
@MainActor @Observable
public final class SessionFiles {
    public private(set) var root: URL?
    public private(set) var baseRevision: String?
    public private(set) var isGitRepository = false
    public private(set) var matches: [String] = []
    public private(set) var changedPaths: [String] = []
    public private(set) var selectedPath: String?
    public private(set) var document: SessionFileDocument?
    public private(set) var indexError: String?
    public private(set) var changesError: String?
    /// Automatic refresh is unavailable; manual and ACP-triggered refreshes still work.
    public private(set) var watchError: String?
    public private(set) var documentError: String?
    public private(set) var isLoadingIndex = false
    public private(set) var isLoadingDocument = false
    public private(set) var isSearching = false
    public private(set) var query = ""
    public private(set) var sessionID: UUID?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var index: FileIndex?
    @ObservationIgnored private var watcher: SessionFileChanges?
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var invalidation: Task<Void, Never>?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var read: Task<SessionFileDocument, any Error>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var lastScan: ContinuousClock.Instant?
    /// Sustained events, e.g. a build writing ignored output, rescan at most once per interval.
    @ObservationIgnored var scanInterval: Duration = .seconds(1)
    // Test seam for a file read that finishes after selection replacement or window closure.
    @ObservationIgnored var documentLoader: @MainActor (URL, URL) async throws -> SessionFileDocument = {
        try await SessionFileDocument.load(root: $0, url: $1)
    }
    // Test seam for root replacement while an asynchronous scan is in flight.
    @ObservationIgnored var indexLoader: @MainActor (URL, Bool) async throws -> FileIndex = {
        try await FileIndex.load(in: $0, isGitRepository: $1)
    }
    // Test seam for a watcher that cannot start.
    @ObservationIgnored var watcherFactory:
        @MainActor (URL, @escaping @MainActor @Sendable () -> Void) async throws -> SessionFileChanges = {
            try await SessionFileChanges(directory: $0, onChange: $1)
        }

    public init() {}

    public func attach(_ session: SessionRecord?) async {
        guard sessionID != session?.id || !attached else { return }
        close()
        guard let session else { return }
        sessionID = session.id
        let token = generation
        defer { if generation == token, !attached { close() } }
        let directory = URL(filePath: session.workingDirectory)
        let root: URL = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScopedFileAccess(roots: [directory]).roots[0])
            }
        }
        guard isCurrent(token) else { return }
        self.root = root
        baseRevision = session.baseRevision
        // The first scan also starts watching.
        await refresh()
        if isCurrent(token) { attached = true }
    }

    /// Coalesces filesystem and ACP invalidations, including one retry for changes during a scan.
    public func invalidate() {
        guard root != nil else { return }
        if scan != nil { needsRefresh = true; return }
        guard invalidation == nil else { return }
        let token = generation
        let delay = delayBeforeNextScan(atLeast: .milliseconds(150))
        invalidation = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token else { return }
            self.invalidation = nil
            await self.refresh()
        }
    }

    public func refresh() async {
        guard let root else { return }
        if let scan { needsRefresh = true; await scan.value; return }
        let token = generation
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.scan = nil } }
            repeat {
                self.needsRefresh = false
                self.lastScan = .now
                await self.scanOnce(root, token: token)
                guard self.needsRefresh, self.isCurrent(token) else { break }
                do { try await Task.sleep(for: self.delayBeforeNextScan(atLeast: .zero)) } catch { break }
            } while self.needsRefresh && self.isCurrent(token)
        }
        scan = task
        await task.value
    }

    private func delayBeforeNextScan(atLeast minimum: Duration) -> Duration {
        guard let lastScan else { return minimum }
        return max(minimum, lastScan + scanInterval - .now)
    }

    private func scanOnce(_ root: URL, token: UUID) async {
        // Only a scan without published files is loading; background refreshes keep the current state visible.
        isLoadingIndex = index == nil
        let git: Bool
        do {
            guard await Self.rootIsUnchanged(root) else { throw SessionFileDocument.Failure.outsideScope }
            git = try await SessionFileChanges.isGitRepository(in: root)
        } catch {
            if isCurrent(token) { fail(error, changes: true) }
            return
        }
        guard isCurrent(token) else { return }
        if git != isGitRepository {
            isGitRepository = git
            changedPaths = []
            changesError = nil
            watcher?.close(); watcher = nil
        }
        await watch(root, token: token)
        guard isCurrent(token) else { return }
        do {
            let updated = try await indexLoader(root, git)
            // A scan can suspend while the pathname is replaced; validate again before publishing.
            let stillOriginalRoot = await Self.rootIsUnchanged(root)
            guard isCurrent(token) else { return }
            guard stillOriginalRoot else { throw SessionFileDocument.Failure.outsideScope }
            index = updated
            indexError = nil
            // Keep the visible matches until the refreshed ones replace them.
            search(query, clearing: false)
        } catch {
            guard isCurrent(token) else { return }
            let outside = error as? SessionFileDocument.Failure == .outsideScope
            fail(error, changes: outside)
            if outside { return }
        }
        isLoadingIndex = false
        guard git else { return }
        do {
            let paths = try await SessionFileChanges.paths(in: root, baseRevision: baseRevision)
            let stillOriginalRoot = await Self.rootIsUnchanged(root)
            guard isCurrent(token) else { return }
            guard stillOriginalRoot else { throw SessionFileDocument.Failure.outsideScope }
            changedPaths = paths
            changesError = nil
        } catch {
            guard isCurrent(token) else { return }
            changedPaths = []
            changesError = error.localizedDescription
        }
    }

    /// Watching is advisory: a failure leaves manual and ACP-triggered refreshes working, and is retried.
    private func watch(_ root: URL, token: UUID) async {
        guard watcher == nil else { return }
        do {
            let observer = try await watcherFactory(root) { [weak self] in self?.invalidate() }
            guard isCurrent(token) else { observer.close(); return }
            watcher = observer
            watchError = nil
        } catch {
            if isCurrent(token) { watchError = error.localizedDescription }
        }
    }

    private func fail(_ error: any Error, changes: Bool) {
        indexError = error.localizedDescription
        search?.cancel(); search = nil
        isSearching = false
        index = nil; matches = []; isLoadingIndex = false
        if changes { changedPaths = []; changesError = indexError }
    }

    private func isCurrent(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }

    public func setQuery(_ query: String) { search(query, clearing: true) }

    private func search(_ query: String, clearing: Bool) {
        // A background re-run shows progress only when it continues a visible search.
        let showsProgress = clearing || isSearching
        self.query = query
        search?.cancel()
        isSearching = false
        guard let index else { matches = []; return }
        if query.isEmpty { matches = Array(index.paths.prefix(100)); return }
        if clearing { matches = [] }
        isSearching = showsProgress
        let token = generation
        let work = Task.detached { try index.matching(query) }
        search = Task { [weak self] in
            do {
                let paths = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.matches = paths
                self.isSearching = false
            } catch { /* Replaced searches leave the current results in place. */  }
        }
    }

    private static func rootIsUnchanged(_ root: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScopedFileAccess.isCanonical(root))
            }
        }
    }

    public func open(path: String, in sessionID: UUID) async {
        guard self.sessionID == sessionID, let root else { return }
        read?.cancel()
        selection = UUID()
        let token = selection
        selectedPath = path
        document = nil
        documentError = nil
        isLoadingDocument = true
        defer { if selection == token { isLoadingDocument = false; read = nil } }
        let url = root.appending(path: path).standardizedFileURL
        let task = Task { try await self.documentLoader(root, url) }
        read = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard selection == token, !Task.isCancelled else { return }
            document = loaded
        } catch {
            guard selection == token, !Task.isCancelled else { return }
            documentError = error.localizedDescription
        }
    }

    public func closeDocument() {
        selection = UUID()
        read?.cancel(); read = nil
        selectedPath = nil; document = nil; documentError = nil; isLoadingDocument = false
    }

    public func close() {
        generation = UUID()
        sessionID = nil
        attached = false
        watcher?.close(); watcher = nil
        scan?.cancel(); scan = nil
        invalidation?.cancel(); invalidation = nil
        search?.cancel(); search = nil
        closeDocument()
        root = nil; baseRevision = nil; isGitRepository = false
        matches = []; changedPaths = []; index = nil; query = ""
        lastScan = nil; indexError = nil; changesError = nil; watchError = nil; isLoadingIndex = false;
        isSearching = false;
        needsRefresh = false
    }
}
