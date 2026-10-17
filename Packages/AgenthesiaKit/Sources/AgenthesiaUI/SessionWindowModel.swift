public import AgenthesiaCore
public import AppKit
import Observation
import Persistence
import SwiftUI

/// A window's selection and view state; live sessions belong to the app's `SessionManager` (ADR-0026).
@Observable final class SessionWindowModel {
    var showingSetup = true
    private var selectedHistoryID: UUID?
    var owner: LiveSession?
    var history: [SessionRecord] = []
    var projects: [ProjectRecord] = []
    var restored: SessionController?
    var errorMessage: String?
    var isLoadingHistory = false
    var closed = false
    private var selection = UUID()
    let sessions: SessionManager
    let files = SessionFiles()

    init(sessions: SessionManager) { self.sessions = sessions }
    var library: SessionLibrary { sessions.library }
    var displayed: SessionController? { restored ?? owner?.controller }
    /// Continue keeps the same files, so browsing outlasts the startup gap without a controller (ADR-0023).
    var filesSession: SessionRecord? { displayed?.session ?? (owner?.isStarting == true ? owner?.resuming : nil) }
    var canStart: Bool { !closed }
    var canContinue: Bool {
        guard !closed, !showingSetup, !isLoadingHistory, let displayed, displayed.session.agentSessionID != nil else {
            return false
        }
        if let restored { return restored.status == .readOnly }
        return owner?.isLive == false && [.failed, .closed].contains(displayed.status)
            && history.contains { $0.id == displayed.session.id }
    }
    var savedSessions: [SessionRecord] {
        history.filter { record in !sessions.owners.contains { $0.sessionID == record.id } }
    }
    var sidebar: SessionSidebar { SessionSidebar(projects: projects, history: history, owners: sessions.owners) }

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
    }

    /// Wraps in exactly the order shown by SessionSidebarList, including Starting and saved history.
    func navigationTarget(backward: Bool = false, needsInput: Bool = false) -> NavigationTarget? {
        guard !closed else { return nil }
        let sidebar = sidebar
        let rows =
            sidebar.starting.map(NavigationTarget.live)
            + sidebar.groups.flatMap(\.rows).map { row in
                switch row {
                case .live(let owner, _): NavigationTarget.live(owner)
                case .saved(let record): NavigationTarget.saved(record)
                }
            }
        guard !rows.isEmpty else { return nil }
        let selected: AnyHashable? =
            showingSetup
            ? nil
            : selectedHistoryID.map(AnyHashable.init) ?? owner.map { NavigationTarget.live($0).id }
        let index = rows.firstIndex { $0.id == selected }
        let start = index ?? (backward ? 0 : rows.count - 1)
        for step in 1...rows.count {
            let row = rows[(start + (backward ? -step : step) + rows.count) % rows.count]
            if !needsInput { return row }
            if case .live(let owner) = row, owner.activity == .needsInput { return row }
        }
        return nil
    }

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

    func refresh() async {
        do {
            history = try await library.history()
            projects = try await library.projects()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func start(directory: URL, executable: String, arguments: [String]) {
        guard canStart else { return }
        show(
            sessions.start(
                directory: directory,
                agent: AgentInstallRecord(
                    name: URL(filePath: executable).lastPathComponent,
                    executable: executable,
                    arguments: arguments
                )
            )
        )
    }
    /// Continues the displayed session, or shows the owner that already has it live (ADR-0017, ADR-0026).
    func continueRestored() {
        guard canContinue, let session = displayed?.session else { return }
        show(sessions.resume(session))
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
    func close() { closed = true; selection = UUID(); files.close() }
}

/// Owns the app's live sessions; AppKit waits for their event writes and process-group cleanup before
/// terminating.
public final class SessionApplicationDelegate: NSObject, NSApplicationDelegate {
    public internal(set) var sessions = SessionManager()
    private var terminating = false
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

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !sessions.owners.isEmpty else { return .terminateNow }
        if !terminating {
            let activeCount = sessions.owners.count { [.working, .needsInput].contains($0.activity) }
            guard activeCount == 0 || confirmQuit(activeCount) else { return .terminateCancel }
            terminating = true
            Task {
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
