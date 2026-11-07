import ACP
public import AgenthesiaCore
public import AppKit
import Observation
import Persistence
import SwiftUI

/// A window's selection and view state; live sessions belong to the app's `SessionManager` (ADR-0026).
@Observable final class SessionWindowModel {
    /// Whether the window shows the draft (ADR-0040) instead of a session.
    var showingSetup = true
    /// The draft's first message; it moves to the session on Send and comes back if startup fails or is cancelled.
    var draft = PromptDraft()
    /// The project and agent picked in the draft; nil uses the defaults.
    var draftDirectory: URL? { didSet { draftError = nil } }
    var draftAgent: AgentCatalog.Choice? { didSet { draftError = nil } }
    /// Why the last session started from the draft did not start.
    var draftError: String?
    /// Whether the inspector is wanted; `DetailPanes` hides it when the window is too narrow.
    var showingInspector = true
    /// The widths the user last chose for the file pane and the inspector; `DetailPanes` fits them to the window.
    var filePaneWidth: CGFloat = 420
    var inspectorWidth: CGFloat = 260
    private var selectedHistoryID: UUID?
    var owner: LiveSession?
    var history: [SessionRecord] = []
    var projects: [ProjectRecord] = []
    var restored: SessionController?
    /// Sessions whose worktree was merged or discarded, read with history (ADR-0032).
    var outcomes: [UUID: WorktreeOutcome] = [:]
    /// The time of each saved session's last event, read with history (ADR-0039).
    var lastActivity: [UUID: Date] = [:]
    /// Merged sessions whose worktree removal failed, found at each history refresh rather than on every render.
    var leftoverWorktrees: Set<UUID> = []
    /// The discard waiting for confirmation.
    var pendingDiscard: PendingDiscard?
    /// The merge sheet; it opens above the review when that is shown.
    var merge: MergeRequest?
    /// A failed lifecycle action, shown in an alert.
    var alertMessage: String?
    var alertTitle = ""
    var isConfirmingDiscard: Bool {
        get { pendingDiscard != nil }
        set { if !newValue { pendingDiscard = nil } }
    }
    var isShowingAlert: Bool {
        get { alertMessage != nil }
        set { if !newValue { alertMessage = nil } }
    }
    var errorMessage: String?
    var isLoadingHistory = false
    var closed = false
    private var selection = UUID()
    let sessions: SessionManager
    let files = SessionFiles()
    var review: SessionReview?

    var canReview: Bool {
        !closed && !showingSetup && !isLoadingHistory && signIn == nil && files.root != nil && files.isGitRepository
            && files.sessionID == displayed?.session.id
    }

    func openReview() {
        guard canReview, let session = displayed?.session, let root = files.root else { return }
        review = SessionReview(session: session, root: root)
    }

    /// Installed and local agents for the draft; without it, only a custom command (ADR-0036).
    let catalog: AgentCatalog?

    init(sessions: SessionManager, catalog: AgentCatalog? = nil) {
        self.sessions = sessions
        self.catalog = catalog
    }
    var library: SessionLibrary { sessions.library }
    var displayed: SessionController? { restored ?? owner?.controller }
    /// Continue keeps the same files, so browsing outlasts the startup gap without a controller (ADR-0023).
    /// A removed worktree has no files left to browse.
    var filesSession: SessionRecord? {
        guard let session = displayed?.session ?? (owner?.isStarting == true ? owner?.resuming : nil),
            outcome(of: session.id) == nil
        else { return nil }
        return session
    }
    var canStart: Bool { !closed }
    /// The draft is not the session that stays displayed behind it.
    var inDraft: Bool { showingSetup && canStart }
    var windowTitle: String { inDraft ? "New Session" : displayed?.title ?? displayed?.session.title ?? "New Session" }
    var windowSubtitle: String {
        inDraft ? "" : projects.first { $0.id == displayed?.session.projectID }?.name ?? ""
    }
    /// Each session's unsent composer, by session ID, for as long as the window lives. An empty one is not kept.
    var composerDrafts: [UUID: ComposerDraft] = [:]
    /// The composer of the displayed session.
    var composer: ComposerDraft {
        get { displayed.flatMap { composerDrafts[$0.session.id] } ?? ComposerDraft() }
        set {
            guard let id = displayed?.session.id else { return }
            composerDrafts[id] = newValue == ComposerDraft() ? nil : newValue
        }
    }
    var find = TranscriptFindState()
    /// Counts the requests (⌘L) to focus the composer's text.
    var composerFocusRequests = 0
    /// The composer card is shown: not the draft, a restored session's Continue card or a sign-in.
    var canFocusComposer: Bool {
        !closed && !inDraft && !isLoadingHistory && restored == nil && signIn == nil && owner?.controller != nil
    }
    func focusComposer() {
        guard canFocusComposer else { return }
        composerFocusRequests += 1
    }
    var canFind: Bool { !closed && !inDraft && !isLoadingHistory && displayed != nil }
    func openFind() {
        guard canFind else { return }
        find.isOpen = true
        find.focusRequests += 1
        updateFindMatches()
    }
    func closeFind() { find = TranscriptFindState() }
    func updateFindMatches() {
        guard find.isOpen, let items = displayed?.transcript.items else { return }
        find.matches = TranscriptSearch.matches(find.query, in: items)
    }
    /// Steps to a match, recounting first so that what arrived since is found too.
    func findNext(backward: Bool = false) {
        updateFindMatches()
        if let item = find.step(in: find.matches, backward: backward) { find.reveal = .init(item: item) }
    }
    func nextFailedToolCall() {
        guard canFind, let items = displayed?.transcript.items else { return }
        if let item = find.step(in: TranscriptSearch.failedToolCalls(in: items), backward: false) {
            find.reveal = .init(item: item)
        }
    }
    /// The queued message being edited may have been sent while another session was shown.
    func dropStaleQueueEdit() {
        guard let id = composer.editingQueueID, displayed?.queuedPrompts.contains(where: { $0.id == id }) != true
        else { return }
        composer.finishEditing()
    }
    /// The displayed session's identity, or the launch form while none is shown or still starting.
    var target: WindowTarget {
        guard !closed, !showingSetup, let id = displayed?.session.id ?? owner?.sessionID else { return .launch }
        return .session(id)
    }
    var canContinue: Bool {
        guard !closed, !showingSetup, !isLoadingHistory, let displayed, displayed.session.agentSessionID != nil,
            outcome(of: displayed.session.id) == nil, !sessions.isDiscarding(displayed.session.id)
        else { return false }
        if let restored { return restored.status == .readOnly }
        return owner?.isLive == false && [.failed, .closed].contains(displayed.status)
            && history.contains { $0.id == displayed.session.id }
    }
    var savedSessions: [SessionRecord] {
        history.filter { record in !sessions.owners.contains { $0.sessionID == record.id } }
    }
    /// The sidebar's search text; navigation and the sections only see the rows it matches.
    var sidebarQuery = ""
    /// Counts the requests (⌥⌘F) to focus the sidebar's search field.
    var searchFocusRequests = 0
    var sidebar: SessionSidebar {
        SessionSidebar(
            projects: projects,
            history: history,
            owners: sessions.owners,
            activity: lastActivity,
            query: sidebarQuery
        )
    }

    var sidebarSelection: AnyHashable? {
        get {
            showingSetup || closed
                ? nil : selectedHistoryID.map(AnyHashable.init) ?? owner.map { NavigationTarget.live($0).id }
        }
        set {
            guard !closed, let id = newValue, id != sidebarSelection else { return }
            if let owner = sessions.owners.first(where: { NavigationTarget.live($0).id == id }) {
                show(owner)
            } else if let record = history.first(where: { AnyHashable($0.id) == id }) {
                showingSetup = false
                selectedHistoryID = record.id
                let token = UUID()
                selection = token
                Task {
                    guard selection == token, !closed else { return }
                    await showHistory(record)
                }
            }
        }
    }

    /// The sign-in the displayed live session waits for (ADR-0033).
    var signIn: LiveSession.SignIn? { closed || showingSetup || restored != nil ? nil : owner?.signIn }
    /// A terminal sign-in, shown as a sheet. Clearing it cancels a running command or hides a failed one.
    var signInTerminal: SignInTerminal? {
        get { closed || restored != nil ? nil : owner?.signInTerminal }
        set {
            guard newValue == nil, let owner, let terminal = owner.signInTerminal else { return }
            if terminal.exitMessage == nil {
                Task { await owner.cancelSignIn() }
            } else {
                owner.dismissSignInTerminal()
            }
        }
    }
    func signIn(with id: ACP.AuthMethodID) {
        guard signIn != nil, let owner else { return }
        Task { await owner.signIn(with: id) }
    }
    func cancelSignIn() {
        guard let owner else { return }
        Task { await owner.cancelSignIn() }
    }

    var canEnd: Bool {
        !closed && !showingSetup && !isLoadingHistory && restored == nil
            && sessions.owners.contains { $0 === owner }
    }
    var canStop: Bool {
        guard !closed, !showingSetup, !isLoadingHistory, restored == nil, let session = owner?.controller else {
            return false
        }
        return (session.status == .running || session.status == .stopping || !session.pendingInputs.isEmpty)
            && !(session.status == .stopping && session.queuePaused)
    }
    var canDiscard: Bool {
        guard !showingSetup, !isLoadingHistory, let session = displayed?.session else { return false }
        return canDiscard(session)
    }
    /// The session has a worktree Agenthesia created, without an outcome yet, and is not starting. A merge whose
    /// removal failed leaves its worktree for Discard to remove.
    func canDiscard(_ session: SessionRecord) -> Bool {
        guard !closed else { return false }
        switch outcome(of: session.id) {
        case nil: break
        case .merged: guard leftoverWorktrees.contains(session.id) else { return false }
        case .discarded: return false
        }
        return sessions.canDiscard(session, project: projects.first { $0.id == session.projectID })
    }
    var canMerge: Bool { canMergeSession && !hasNoChanges }
    private var canMergeSession: Bool {
        guard !closed, !showingSetup, !isLoadingHistory, let session = displayed?.session else { return false }
        return outcome(of: session.id) == nil
            && sessions.canDiscard(session, project: projects.first { $0.id == session.projectID })
    }
    /// The displayed session's file list is loaded and empty; while it loads or failed, the merge sheet decides.
    private var hasNoChanges: Bool { files.sessionID == displayed?.session.id && files.hasNoChanges }
    /// Why Merge is disabled when nothing else is in the way.
    var mergeHelp: String? { canMergeSession && hasNoChanges ? "No changes to merge" : nil }
    var mergeCommandTitle: String { displayed?.session.baseBranch.map { "Merge into \($0)…" } ?? "Merge…" }
    /// The displayed transcript knows an outcome recorded after the last history refresh.
    func outcome(of id: UUID) -> WorktreeOutcome? {
        (displayed?.session.id == id ? displayed?.transcript.worktreeOutcome : nil) ?? outcomes[id]
    }

    struct PendingDiscard: Identifiable {
        let session: SessionRecord
        /// Nil when Git could not count what would be lost; the alert still warns.
        let summary: SessionManager.DiscardSummary?
        /// The base branch of a merge whose worktree is left over; nothing of it is lost.
        var mergedInto: String?
        var id: UUID { session.id }

        var title: String { "Discard the worktree of “\(session.title ?? "New Session")”?" }
        var message: String {
            if let mergedInto {
                return
                    "Its changes are already merged into \(mergedInto). The leftover worktree and its branch will be removed."
            }
            guard let summary else {
                return "Its uncommitted files and the commits on its branch will be deleted. This cannot be undone."
            }
            let files =
                summary.uncommittedFiles == 1 ? "1 uncommitted file" : "\(summary.uncommittedFiles) uncommitted files"
            let commits = summary.commits == 1 ? "1 commit" : "\(summary.commits) commits"
            return "\(files) and \(commits) on \(summary.branch) will be deleted. This cannot be undone."
        }
    }

    var canResumeQueue: Bool {
        guard !closed, !showingSetup, !isLoadingHistory, restored == nil, let session = owner?.controller else {
            return false
        }
        return [.idle, .running].contains(session.status) && session.queuePaused
    }

    enum NavigationTarget: Identifiable {
        case live(LiveSession)
        case saved(SessionRecord)

        var id: AnyHashable {
            switch self {
            case .live(let owner): owner.sessionID.map(AnyHashable.init) ?? AnyHashable(owner.id)
            case .saved(let record): AnyHashable(record.id)
            }
        }

        /// The window value that shows this session; nil while a starting session has no identity yet.
        var windowTarget: WindowTarget? {
            switch self {
            case .live(let owner): owner.sessionID.map(WindowTarget.session)
            case .saved(let record): .session(record.id)
            }
        }
    }

    /// Wraps in exactly the order shown by SessionSidebarList: Needs You, Working, then saved history.
    func navigationTarget(backward: Bool = false, needsInput: Bool = false) -> NavigationTarget? {
        guard !closed else { return nil }
        let rows = sidebar.rows.map { row in
            switch row.source {
            case .live(let owner): NavigationTarget.live(owner)
            case .saved(let record): NavigationTarget.saved(record)
            }
        }
        guard !rows.isEmpty else { return nil }
        let selected = sidebarSelection
        let index = rows.firstIndex { $0.id == selected }
        let start = index ?? (backward ? 0 : rows.count - 1)
        for step in 1...rows.count {
            let row = rows[(start + (backward ? -step : step) + rows.count) % rows.count]
            if !needsInput { return row }
            if case .live(let owner) = row, owner.activity == .needsInput { return row }
        }
        return nil
    }

    /// One entry per ⌘1…⌘9 item of Session → Switch to Session; nil for a number without a row.
    var numberedSessions: [SessionSidebar.Row?] {
        let rows = closed ? [] : sidebar.numberedRows
        return (0..<SessionSidebar.numberedCount).map { rows.indices.contains($0) ? rows[$0] : nil }
    }

    func switchToSession(_ row: SessionSidebar.Row) { sidebarSelection = row.id }

    func navigate(backward: Bool = false, needsInput: Bool = false) async {
        guard let row = navigationTarget(backward: backward, needsInput: needsInput) else { return }
        switch row {
        case .live(let owner): show(owner)
        case .saved(let record): await showHistory(record)
        }
    }

    func endSession() async {
        guard canEnd, let owner else { return }
        await sessions.end(owner)
        await refresh()
    }
    func stop() async {
        guard canStop, let owner else { return }
        await owner.stop()
    }
    func resumeQueue() async {
        guard canResumeQueue, let session = owner?.controller else { return }
        do { try await session.resumeQueue() } catch { errorMessage = error.localizedDescription }
    }

    /// Counts what would be lost and asks for confirmation.
    func requestDiscard(_ session: SessionRecord) async {
        guard canDiscard(session) else { return }
        if case .merged(_, let base) = outcome(of: session.id) {
            pendingDiscard = PendingDiscard(session: session, summary: nil, mergedInto: base)
            return
        }
        let summary: SessionManager.DiscardSummary?
        do { summary = try await sessions.discardSummary(session) } catch let error as SessionManager.DiscardError {
            showAlert("Cannot Discard the Worktree", error)
            return
        } catch { summary = nil }
        guard !closed else { return }
        pendingDiscard = PendingDiscard(session: session, summary: summary)
    }
    /// Discards the confirmed worktree; a window showing the session then shows it read-only with the outcome.
    /// The alert supplies its captured value because dismissal clears `pendingDiscard` before this task runs.
    func confirmDiscard(_ pending: PendingDiscard) async {
        pendingDiscard = nil
        let id = pending.session.id
        let shown = displayed?.session.id == id || owner?.sessionID == id
        do { try await sessions.discard(pending.session) } catch { showAlert("Cannot Discard the Worktree", error) }
        await refreshShowing(id, shown: shown)
    }

    /// Opens the merge sheet for the displayed session, then asks Git what blocks the merge.
    func requestMerge() async {
        guard canMerge, let displayed else { return }
        let request = MergeRequest(session: displayed.session, message: displayed.transcript.mergeMessage)
        merge = request
        do { request.check = try await sessions.mergeCheck(request.session) } catch {
            request.check = .blocked(error.localizedDescription)
        }
    }
    /// Merges; failures stay in the sheet so the message is kept for another attempt. After the commit exists the
    /// sheet and review close, and a window showing the session shows it read-only with the outcome.
    func confirmMerge(_ request: MergeRequest) async {
        guard request.canMerge else { return }
        request.isMerging = true
        request.failure = nil
        defer { request.isMerging = false }
        let id = request.session.id
        let shown = displayed?.session.id == id || owner?.sessionID == id
        var committed: SessionManager.MergeError?
        do {
            try await sessions.merge(request.session, message: request.message)
        } catch let error as SessionManager.MergeError {
            switch error {
            case .worktreeKept, .notRecorded: committed = error
            default:
                request.failure = error
                return
            }
        } catch {
            // Refused before Git ran, so nothing changed.
            request.failure = .blocked(error.localizedDescription)
            return
        }
        if merge === request { merge = nil }
        if review?.id == id { review = nil }
        await refreshShowing(id, shown: shown)
        // After the sheets have gone, so the alert is not lost behind a dismissing sheet.
        if let committed { showAlert("The Merge Did Not Finish", committed) }
    }

    private func showAlert(_ title: String, _ error: any Error) {
        alertTitle = title
        alertMessage = error.localizedDescription
    }

    private func refreshShowing(_ id: UUID, shown: Bool) async {
        await refresh()
        if shown, !closed, let record = history.first(where: { $0.id == id }) { await showHistory(record) }
    }

    func refresh() async {
        do {
            history = try await library.history()
            projects = try await library.projects()
            (outcomes, lastActivity) = try await library.lastEvents()
            leftoverWorktrees = Set(
                history.filter {
                    if case .merged = outcomes[$0.id] {
                        FileManager.default.fileExists(atPath: $0.workingDirectory)
                    } else {
                        false
                    }
                }.map(\.id)
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    /// Shows the target as the window opens, including after relaunch; a vanished session opens the launch form.
    func restore(_ target: WindowTarget) async {
        guard case .session(let id) = target else { return }
        await refresh()
        if let record = history.first(where: { $0.id == id }) {
            await showHistory(record)
        } else if let live = sessions.owner(of: id) {
            show(live)
        }
    }
    /// Shows a session a notification led to (ADR-0030). A blank launch form that is the only window
    /// fills in place, which also covers an activation with no window open: the system makes that window
    /// to receive the URL. Otherwise the session gets its own window, or the one that already shows it.
    func activate(_ target: WindowTarget, isBlank: Bool, windowCount: Int, openWindow: (WindowTarget) -> Void) async {
        guard !closed, case .session = target else { return }
        if isBlank, self.target == .launch, windowCount <= 1 {
            await restore(target)
        } else {
            openWindow(target)
        }
    }
    func start(directory: URL, executable: String, arguments: [String]) {
        start(
            directory: directory,
            agent: AgentCatalog.record(custom: .init(executable: executable, arguments: arguments))
        )
    }
    @discardableResult func start(
        directory: URL,
        agent: AgentInstallRecord,
        initialPrompt: PromptDraft? = nil
    ) -> LiveSession? {
        guard canStart else { return nil }
        let owner = sessions.start(directory: directory, agent: agent, initialPrompt: initialPrompt)
        show(owner)
        return owner
    }

    /// Known projects, most recently used first; the first is the draft's default (ADR-0040).
    var recentProjects: [ProjectRecord] { ProjectRecord.recent(projects, history: history) }
    /// The draft's project: the one picked, else the project of the newest session.
    var selectedDirectory: URL? {
        draftDirectory ?? recentProjects.first.map { URL(filePath: $0.rootPath, directoryHint: .isDirectory) }
    }
    /// The draft's agent: the one picked while it is still offered, else the catalog's default.
    var selectedAgent: AgentCatalog.Choice? {
        if let draftAgent, record(for: draftAgent) != nil { return draftAgent }
        return catalog?.defaultChoice
    }
    func record(for choice: AgentCatalog.Choice) -> AgentInstallRecord? {
        if case .custom(let command) = choice { return AgentCatalog.record(custom: command) }
        return catalog?.record(for: choice)
    }
    var canStartDraft: Bool {
        canStart && showingSetup && !draft.isEmpty && selectedDirectory != nil
            && selectedAgent.flatMap(record(for:)) != nil
    }

    /// Opens the draft with `project` selected; the typed message and agent stay (ADR-0040).
    func newSession(in project: ProjectRecord) {
        draftDirectory = URL(filePath: project.rootPath, directoryHint: .isDirectory)
        showingSetup = true
    }

    /// Send in the draft: starts the session with the draft as its initial prompt. An empty draft starts nothing.
    func startDraft() {
        guard canStartDraft, let directory = selectedDirectory, let choice = selectedAgent,
            let agent = record(for: choice)
        else { return }
        draftError = nil
        // Only a session that started is remembered: a failed or cancelled start keeps the last agent (ADR-0040).
        start(directory: directory, agent: agent, initialPrompt: draft)?.onInitialPromptSubmitted = { [catalog] in
            catalog?.remember(choice)
        }
        draft = PromptDraft()
    }

    /// The displayed owner was started from the draft and failed or was cancelled before its prompt was submitted.
    var abandonedStart: LiveSession? {
        guard !closed, !showingSetup, restored == nil, let owner, owner.initialPrompt != nil, !owner.isLive else {
            return nil
        }
        return owner
    }

    /// Returns the draft unchanged, with the error, and ends the owner: the session was not started (ADR-0040).
    func returnToDraft() async {
        guard let owner = abandonedStart, let prompt = owner.initialPrompt else { return }
        draft = prompt
        draftError = owner.errorMessage
        self.owner = nil
        showLive()
        showingSetup = true
        await sessions.end(owner)
    }
    /// Continues the displayed session, or shows the owner that already has it live (ADR-0017, ADR-0026).
    func continueRestored() {
        guard canContinue, let session = displayed?.session, let owner = sessions.resume(session) else { return }
        show(owner)
    }
    func showHistory(_ record: SessionRecord) async {
        guard !closed else { return }
        showingSetup = false
        selectedHistoryID = record.id
        if let live = sessions.owner(of: record.id) { return show(live) }
        let token = UUID()
        selection = token
        isLoadingHistory = true
        errorMessage = nil
        defer { if selection == token { isLoadingHistory = false } }
        do {
            let controller = try await SessionController.restore(id: record.id, store: library.store())
            guard selection == token, !closed else { return }
            restored = controller
        } catch { if selection == token { errorMessage = error.localizedDescription } }
    }
    func show(_ owner: LiveSession) {
        guard !closed else { return }
        self.owner = owner; showingSetup = false; showLive()
    }
    func showLive() {
        selectedHistoryID = nil; selection = UUID(); isLoadingHistory = false; restored = nil; errorMessage = nil
    }
    /// Detaches the window; its sessions keep running.
    func close() {
        closed = true; selection = UUID(); files.close(); review = nil; merge = nil
        sessions.setShown(nil, in: self)
    }
}

/// Owns the app's live sessions; AppKit waits for their event writes and process-group cleanup before
/// terminating.
public final class SessionApplicationDelegate: NSObject, NSApplicationDelegate {
    public internal(set) var sessions = SessionManager()
    var catalog = AgentCatalog.shared
    private var terminating = false
    private var attention: SessionAttention?
    var confirmQuit: (Int) -> Bool = { count in
        let alert = NSAlert()
        alert.messageText = "Quit Agenthesia?"
        alert.informativeText =
            count == 1
            ? "1 session is working or needs input. Quitting will end it."
            : "\(count) sessions are working or need input. Quitting will end them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var terminationReply: (NSApplication) -> Void = { $0.reply(toApplicationShouldTerminate: true) }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Notification Center needs an app bundle, so package tests and the CLI never reach it.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let system = SystemAttention()
        let attention = SessionAttention(sessions: sessions, sink: system)
        system.attention = attention
        self.attention = attention
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A merge in saved history has no owner but must finish before the app quits.
        guard !sessions.owners.isEmpty || !sessions.mergingIDs.isEmpty || catalog.signIn != nil else {
            return .terminateNow
        }
        if !terminating {
            let activeCount = sessions.owners.count { [.working, .needsInput].contains($0.activity) }
            guard activeCount == 0 || confirmQuit(activeCount) else { return .terminateCancel }
            terminating = true
            Task {
                await catalog.closeSignInForQuit()
                await sessions.closeAll()
                terminationReply(sender)
            }
        }
        return .terminateLater
    }
}

/// Detaches the window model when its window closes, which stops its file observation.
struct SessionWindowLifetime: NSViewRepresentable {
    let model: SessionWindowModel
    final class View: NSView {
        var model: SessionWindowModel?
        private weak var observedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowClosing),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        @objc private func windowClosing(_ notification: Notification) { model?.close() }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.model = model; return view }
    func updateNSView(_ view: View, context: Context) {}
}
