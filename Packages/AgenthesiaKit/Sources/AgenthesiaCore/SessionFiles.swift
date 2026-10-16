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
    // Test seam for a file read that finishes after selection replacement or window closure.
    @ObservationIgnored var documentLoader: @MainActor (URL, URL) async throws -> SessionFileDocument = {
        try await SessionFileDocument.load(root: $0, url: $1)
    }
    // Test seam for root replacement while an asynchronous scan is in flight.
    @ObservationIgnored var indexLoader: @MainActor (URL) async throws -> FileIndex = {
        try await FileIndex.load(in: $0)
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
        guard generation == token, !Task.isCancelled else { return }
        self.root = root
        baseRevision = session.baseRevision
        isLoadingIndex = true
        do {
            let git = try await SessionFileChanges.isGitRepository(in: root)
            guard generation == token, !Task.isCancelled else { return }
            isGitRepository = git
            let observer = try await SessionFileChanges(directory: root) { [weak self] in self?.invalidate() }
            guard generation == token, !Task.isCancelled else { observer.close(); return }
            watcher = observer
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            changesError = error.localizedDescription
        }
        guard generation == token, !Task.isCancelled else { return }
        await refresh()
        if generation == token, !Task.isCancelled { attached = true }
    }

    /// Coalesces filesystem and ACP invalidations, including one retry for changes during a scan.
    public func invalidate() {
        guard root != nil else { return }
        if scan != nil { needsRefresh = true; return }
        guard invalidation == nil else { return }
        let token = generation
        invalidation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
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
                self.isLoadingIndex = true
                do {
                    let isOriginalRoot = await Self.rootIsUnchanged(root)
                    guard self.generation == token, !Task.isCancelled else { return }
                    guard isOriginalRoot else {
                        self.indexError = SessionFileDocument.Failure.outsideScope.localizedDescription
                        self.changesError = self.indexError
                        self.search?.cancel(); self.search = nil
                        self.isSearching = false
                        self.index = nil; self.matches = []; self.changedPaths = []; self.isLoadingIndex = false
                        return
                    }
                    let git = try await SessionFileChanges.isGitRepository(in: root)
                    guard self.generation == token, !Task.isCancelled else { return }
                    if git != self.isGitRepository || self.watcher == nil {
                        let observer = try await SessionFileChanges(directory: root) { [weak self] in self?.invalidate()
                        }
                        guard self.generation == token, !Task.isCancelled else { observer.close(); return }
                        self.watcher?.close()
                        self.watcher = observer
                        self.isGitRepository = git
                        self.changedPaths = []
                        self.changesError = nil
                    }
                    let updated = try await self.indexLoader(root)
                    // A scan can suspend while the pathname is replaced; validate again before publishing.
                    let stillOriginalRoot = await Self.rootIsUnchanged(root)
                    guard self.generation == token, !Task.isCancelled else { return }
                    guard stillOriginalRoot else { throw SessionFileDocument.Failure.outsideScope }
                    self.index = updated
                    self.indexError = nil
                    self.setQuery(self.query)
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.indexError = error.localizedDescription
                    self.search?.cancel(); self.search = nil
                    self.isSearching = false
                    self.index = nil
                    self.matches = []
                    if error as? SessionFileDocument.Failure == .outsideScope {
                        self.changedPaths = []
                        self.changesError = self.indexError
                        self.isLoadingIndex = false
                        return
                    }
                }
                self.isLoadingIndex = false
                if self.isGitRepository {
                    do {
                        let paths = try await SessionFileChanges.paths(in: root, baseRevision: self.baseRevision)
                        let stillOriginalRoot = await Self.rootIsUnchanged(root)
                        guard self.generation == token, !Task.isCancelled else { return }
                        guard stillOriginalRoot else { throw SessionFileDocument.Failure.outsideScope }
                        self.changedPaths = paths
                        self.changesError = nil
                    } catch {
                        guard self.generation == token, !Task.isCancelled else { return }
                        self.changedPaths = []
                        self.changesError = error.localizedDescription
                    }
                }
            } while self.needsRefresh && self.generation == token && !Task.isCancelled
        }
        scan = task
        await task.value
    }

    public func setQuery(_ query: String) {
        self.query = query
        search?.cancel()
        isSearching = false
        guard let index else { matches = []; return }
        if query.isEmpty { matches = Array(index.paths.prefix(100)); return }
        matches = []
        isSearching = true
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
                continuation.resume(returning: ScopedFileAccess(roots: [root]).roots[0] == root)
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
        indexError = nil; changesError = nil; isLoadingIndex = false; isSearching = false; needsRefresh = false
    }
}
