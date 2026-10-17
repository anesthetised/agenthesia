public import AgenthesiaCore
public import AppKit
import Observation
import Persistence
import SwiftUI

/// A window's selection and view state; live sessions belong to the app's `SessionManager` (ADR-0026).
@Observable final class SessionWindowModel {
    var owner: LiveSession?
    var history: [SessionRecord] = []
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
        guard !closed, let displayed, displayed.session.agentSessionID != nil else { return false }
        if let restored { return restored.status == .readOnly }
        return owner?.isLive == false && [.failed, .closed].contains(displayed.status)
            && history.contains { $0.id == displayed.session.id }
    }
    /// Sessions with an owner are listed as live, failed ones included.
    var savedSessions: [SessionRecord] {
        history.filter { record in !sessions.owners.contains { $0.sessionID == record.id } }
    }

    func refresh() async {
        do {
            history = try await library.history()
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
    func show(_ owner: LiveSession) { self.owner = owner; showLive() }
    func showLive() { selection = UUID(); isLoadingHistory = false; restored = nil; errorMessage = nil }
    /// Detaches the window; its sessions keep running.
    func close() { closed = true; selection = UUID(); files.close() }
}

/// Owns the app's live sessions; AppKit waits for their event writes and process-group cleanup before
/// terminating.
public final class SessionApplicationDelegate: NSObject, NSApplicationDelegate {
    public internal(set) var sessions = SessionManager()
    private var terminating = false
    var terminationReply: (NSApplication) -> Void = { $0.reply(toApplicationShouldTerminate: true) }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !sessions.owners.isEmpty else { return .terminateNow }
        if !terminating {
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
