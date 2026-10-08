import AgenthesiaCore
public import AppKit
import Observation
import Persistence
import SwiftUI

@Observable final class SessionWindowModel {
    let id = UUID()
    var owner: LiveSession?
    var history: [SessionRecord] = []
    var restored: SessionController?
    var errorMessage: String?
    var isLoadingHistory = false
    var closed = false
    private var starting = false
    private var selection = UUID()
    let library: SessionLibrary

    init(library: SessionLibrary = .shared) { self.library = library }
    var displayed: SessionController? { restored ?? owner?.controller }
    var canStart: Bool {
        !closed && !starting && (owner == nil || owner?.isClosed == true || owner?.errorMessage != nil)
    }

    func refresh() async {
        do { history = try await library.history() } catch { errorMessage = error.localizedDescription }
    }
    func start(directory: URL, executable: String, arguments: [String]) async {
        guard canStart else { return }
        starting = true
        defer { starting = false }
        await owner?.close()
        guard !closed else { return }
        restored = nil
        selection = UUID()
        errorMessage = nil
        let owner = LiveSession(library: library)
        self.owner = owner
        await owner.start(
            directory: directory,
            agent: AgentInstallRecord(
                name: URL(filePath: executable).lastPathComponent,
                executable: executable,
                arguments: arguments
            )
        )
        await refresh()
    }
    func showHistory(_ record: SessionRecord) async {
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
    func showLive() { selection = UUID(); isLoadingHistory = false; restored = nil; errorMessage = nil }
    func close() async { closed = true; selection = UUID(); await owner?.close() }
}

/// AppKit waits for asynchronous event writes and process-group cleanup before terminating.
public final class SessionApplicationDelegate: NSObject, NSApplicationDelegate {
    static var windows: [UUID: SessionWindowModel] = [:]
    private var terminating = false

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.windows.isEmpty else { return .terminateNow }
        if !terminating {
            terminating = true
            Task {
                let models = Array(Self.windows.values)
                for model in models { await model.close() }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

struct SessionWindowLifetime: NSViewRepresentable {
    let model: SessionWindowModel
    final class View: NSView {
        var model: SessionWindowModel?
        private weak var observedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow, let model else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            observedWindow = window
            SessionApplicationDelegate.windows[model.id] = model
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowClosing),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        @objc private func windowClosing(_ notification: Notification) {
            guard let model else { return }
            Task {
                await model.close()
                SessionApplicationDelegate.windows.removeValue(forKey: model.id)
            }
        }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.model = model; return view }
    func updateNSView(_ view: View, context: Context) {}
}
