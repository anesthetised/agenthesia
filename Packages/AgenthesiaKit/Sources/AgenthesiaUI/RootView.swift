public import AgenthesiaCore
import AppKit
public import SwiftUI

public struct RootView: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    @State private var model: SessionWindowModel
    /// The window's persisted value: the system restores it after relaunch (ADR-0026).
    @Binding private var target: WindowTarget
    @State private var prompt = ""
    @State private var attachments: [URL] = []
    @State private var editingQueueID: UUID?
    @State private var savedDraft: (text: String, attachments: [URL])?
    @State private var submitting = false
    @State private var directory = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var showingLog = false
    @State private var showingQuickOpen = false
    @State private var fileQuery = ""

    public init(sessions: SessionManager, target: Binding<WindowTarget> = .constant(.launch)) {
        self.init(model: SessionWindowModel(sessions: sessions), target: target)
    }

    init(model: SessionWindowModel, target: Binding<WindowTarget> = .constant(.launch)) {
        _model = State(initialValue: model)
        _target = target
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                SessionSidebarList(model: model)
                if !model.showingSetup, filesMatchSession {
                    SessionChangedFiles(
                        files: model.files,
                        onOpen: { openFile($0, for: $1) },
                        onReview: model.openReview
                    )
                    .selectionDisabled(true)
                }
            }
            .navigationTitle("Agenthesia")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Session", systemImage: "plus") { model.showingSetup = true }
                    .disabled(!model.canStart)
                Button("Refresh History", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        } detail: {
            VStack(spacing: 0) {
                if model.showingSetup && model.canStart {
                    setup
                } else if model.isLoadingHistory {
                    ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session = model.displayed {
                    HSplitView {
                        VStack(spacing: 0) {
                            LiveTranscript(session: session, pathIndex: pathIndex(for: session)) {
                                openFile($0.path, line: $0.line, for: $1)
                            }
                            .id(session.session.id)
                            Divider()
                            composer(session)
                        }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                        if filesMatchSession, model.files.selectedPath != nil {
                            // The transcript starts under the sidebar, so at the 740 pt window minimum it
                            // takes the sidebar's width (240 pt, more on macOS 26) plus its own minimum.
                            SessionFilePane(files: model.files) { openFile($0, line: $1, for: $2) }
                                .frame(minWidth: 240, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        model.owner?.isStarting == true ? "Starting session…" : "Start a session",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a project and an installed ACP agent.")
                    )
                }
                if model.restored == nil, let diagnostic = model.owner?.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if let error = model.errorMessage ?? (model.restored == nil ? model.owner?.errorMessage : nil) {
                    Text(error).textSelection(.enabled).foregroundStyle(.red).padding().frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                if let path = model.displayed.map({ URL(filePath: $0.session.workingDirectory) })
                    ?? model.owner?.workingDirectory
                {
                    HStack {
                        Text(path.path).lineLimit(1).truncationMode(.middle).help(path.path)
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if showingLog, model.restored == nil, let owner = model.owner {
                    Divider()
                    ScrollView {
                        Text(owner.stderrLog.isEmpty ? "No stderr output." : owner.stderrLog)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.frame(height: 150)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(model.displayed?.title ?? model.displayed?.session.title ?? "New Session")
            .toolbar {
                Button("Quick Open", systemImage: "doc.text.magnifyingglass") {
                    fileQuery = ""
                    model.files.setQuery("")
                    showingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.showingSetup || !filesMatchSession)
                if model.restored == nil, let owner = model.owner {
                    Button("Agent Log", systemImage: "terminal") { showingLog.toggle() }
                    Button(owner.isStarting ? "Cancel Startup" : "End Session", systemImage: "stop.circle") {
                        Task { await model.endSession() }
                    }.disabled(!model.canEnd)
                }
            }
        }
        .frame(minWidth: 740, minHeight: 500)
        .focusedSceneValue(\.sessionWindow, model)
        .background(SessionWindowLifetime(model: model).frame(width: 0, height: 0))
        // Startup persists the session after assigning its ID; refresh only once that write has settled.
        // Ended sessions move to saved history in every window.
        // A finished discard or merge records its outcome, which every window reads with history.
        .task(
            id: HistoryKey(
                owners: model.sessions.owners.filter { !$0.isStarting }.map(\.sessionID),
                discarding: model.sessions.discardingIDs,
                merging: model.sessions.mergingIDs
            )
        ) {
            await model.refresh()
        }
        // Looking at a finished turn in the key window clears its Done mark.
        .onChange(of: viewingUnseenResult, initial: true) {
            if viewingUnseenResult { model.owner?.markSeen() }
        }
        // Notifications lead back to a session through its URL (ADR-0030).
        .onOpenURL { open($0) }
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        // A session in front of the user needs no notification (ADR-0026).
        .onChange(of: shownSessionID, initial: true) { model.sessions.setShown(shownSessionID, in: model) }
        .task {
            await model.restore(target)
            target = model.target
        }
        .onChange(of: model.target) { target = model.target }
        .task(id: model.filesSession?.id) { await model.files.attach(model.filesSession) }
        .onChange(of: model.displayed?.fileRevision) { model.files.invalidate() }
        .onChange(of: model.displayed?.session.id) {
            finishEditing(); showingQuickOpen = false; fileQuery = ""; model.review = nil
        }
        .onChange(of: model.files.sessionID) {
            if model.review?.id != model.files.sessionID { model.review = nil }
        }
        .onChange(of: fileQuery) { model.files.setQuery(fileQuery) }
        .alert(
            model.pendingDiscard?.title ?? "",
            isPresented: $model.isConfirmingDiscard,
            presenting: model.pendingDiscard
        ) { pending in
            Button("Discard", role: .destructive) { Task { await model.confirmDiscard(pending) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text($0.message)
        }
        .alert(model.alertTitle, isPresented: $model.isShowingAlert, presenting: model.alertMessage) { _ in
        } message: {
            Text($0)
        }
        .sheet(isPresented: $showingQuickOpen) {
            let id = model.files.sessionID
            QuickOpen(
                query: $fileQuery,
                paths: model.files.matches,
                isLoading: model.files.isLoadingIndex || model.files.isSearching,
                error: model.files.indexError,
                onSelect: { path in
                    guard model.files.query == fileQuery, model.files.matches.contains(path) else { return }
                    openFile(path, for: id)
                },
                onDismiss: { showingQuickOpen = false }
            )
        }
        .sheet(item: $model.review) { review in
            SessionReviewView(review: review, files: model.files, model: model)
        }
        // Above the review when it is shown, which presents the sheet itself.
        .sheet(item: model.review == nil ? $model.merge : .constant(nil)) { request in
            MergeSheet(request: request) { Task { await model.confirmMerge(request) } }
        }
    }

    private struct HistoryKey: Equatable {
        let owners: [UUID?]
        let discarding: Set<UUID>
        let merging: Set<UUID>
    }

    private var viewingUnseenResult: Bool {
        appearsActive && !model.showingSetup && model.restored == nil && model.owner?.hasUnseenResult == true
    }

    private func open(_ url: URL) {
        guard let opened = WindowTarget(url: url) else { return }
        let windows = NSApp.windows.count { $0.isVisible && $0.canBecomeMain }
        Task {
            await model.activate(opened, isBlank: isBlankLaunchForm, windowCount: windows) { openWindow(value: $0) }
            target = model.target
        }
    }

    private var isBlankLaunchForm: Bool {
        directory.isEmpty && executable.isEmpty && arguments.isEmpty
    }

    private var shownSessionID: UUID? {
        appearsActive && !model.showingSetup ? model.displayed?.session.id : nil
    }

    private var filesMatchSession: Bool {
        model.files.root != nil && model.files.sessionID == model.displayed?.session.id
    }

    /// Empty until the file pane's index belongs to the displayed session.
    private func pathIndex(for session: SessionController) -> TranscriptPathIndex {
        guard filesMatchSession, let root = model.files.root else { return TranscriptPathIndex() }
        return TranscriptPathIndex(
            paths: model.files.indexedPaths,
            roots: [root.path(percentEncoded: false), session.session.workingDirectory],
            revision: model.files.indexRevision
        )
    }

    private func openFile(_ path: String, line: Int? = nil, for id: UUID?) {
        guard let id, model.displayed?.session.id == id, model.files.sessionID == id else { return }
        showingQuickOpen = false
        Task {
            guard model.displayed?.session.id == id, !model.closed else { return }
            await model.files.open(path: path, line: line, in: id)
        }
    }

    private var setup: some View {
        Form {
            Section("New session") {
                HStack {
                    TextField("Project directory", text: $directory)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { directory = panel.url?.path ?? "" }
                    }
                }
                TextField("Agent executable", text: $executable, prompt: Text("/path/to/agent or command on PATH"))
                TextField("Arguments", text: $arguments, axis: .vertical).lineLimit(2...5)
                Text(
                    "One argument per line. Use an installed, authenticated ACP agent. Git projects get a fresh worktree from HEAD; uncommitted and untracked files are not copied. Other directories are used directly."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Start Session") {
                    model.showingSetup = false
                    let command = Self.launchCommand(executable: executable, arguments: arguments)
                    let path = (directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                    model.start(
                        directory: URL(filePath: path),
                        executable: command.executable,
                        arguments: command.arguments
                    )
                }.buttonStyle(.borderedProminent)
                    .disabled(directory.isEmpty || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.formStyle(.grouped)
    }

    private func composer(_ session: SessionController) -> some View {
        let editable = [.idle, .running, .stopping].contains(session.status) && !session.isMerging
        return VStack(alignment: .leading, spacing: 8) {
            if !session.queuedPrompts.isEmpty {
                PromptQueue(
                    session: session,
                    editable: editable && !submitting,
                    onEdit: editQueuedPrompt,
                    onError: { model.errorMessage = $0.localizedDescription }
                )
            }
            if editingQueueID != nil {
                HStack {
                    Text("Editing queued message · Return saves").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Edit", action: finishEditing)
                }
            }
            ComposerInput(
                text: $prompt,
                attachments: $attachments,
                commands: session.transcript.commands,
                isEnabled: editable && !submitting,
                onSubmit: submit,
                attachmentsEditable: editingQueueID == nil,
                onRecall: recallQueuedPrompt,
                onStop: { Task { await model.owner?.stop() } }
            )
            SessionConfigControls(session: session).id(session.session.id)
            HStack {
                Button("Attach Files…", systemImage: "paperclip", action: chooseAttachments)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!editable)
                    .help("Attach files or folders (⇧⌘A)").disabled(editingQueueID != nil || submitting)
                Text(Self.statusText(session))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if [.readOnly, .failed, .closed].contains(session.status) {
                    if model.outcome(of: session.session.id) == nil {
                        Button("Continue", systemImage: "play.fill") { model.continueRestored() }
                            .disabled(!model.canContinue)
                            .help("Reconnect to the agent.")
                    }
                } else if session.status == .running || session.status == .stopping || !session.pendingInputs.isEmpty {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.owner?.stop() } }
                        .disabled(session.status == .stopping && session.queuePaused)
                }
                if editable {
                    Button(
                        editingQueueID != nil
                            ? "Save"
                            : session.status == .idle && session.queuedPrompts.isEmpty
                                ? "Send" : "Queue",
                        systemImage: "arrow.up",
                        action: send
                    )
                    .disabled(!hasDraft || submitting || session.isChangingConfig)
                    Menu("Send options", systemImage: "chevron.down") {
                        Button(hasDraft ? "Send Draft Now" : "Send Queue Now") { submit(.now) }.keyboardShortcut(
                            .return,
                            modifiers: .command
                        )
                        .disabled(
                            (!hasDraft && session.queuedPrompts.isEmpty) || submitting || editingQueueID != nil
                                || session.isChangingConfig
                        )
                        Button("Send Whole Queue Now") { submit(.allNow) }
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                            .disabled(
                                (!hasDraft && session.queuedPrompts.isEmpty) || submitting || editingQueueID != nil
                                    || session.isChangingConfig
                            )
                    }.labelStyle(.iconOnly)
                }
            }
        }
        .padding(16).background(.bar).background { permissionShortcuts(session) }
        .dropDestination(for: URL.self) { urls, _ in
            guard editable, editingQueueID == nil, !submitting else { return false }
            ComposerInput.add(urls, to: &attachments)
            return true
        }
    }

    private var hasDraft: Bool {
        !attachments.isEmpty || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.owner?.workingDirectory
        if panel.runModal() == .OK { ComposerInput.add(panel.urls, to: &attachments) }
    }

    /// ⌥⌘1… answer the oldest pending request with the option its card lists at that position.
    private func permissionShortcuts(_ session: SessionController) -> some View {
        ZStack {
            if let request = session.pendingPermissions.first {
                ForEach(Array(request.options.prefix(9).enumerated()), id: \.offset) { index, option in
                    Button(option.name) { session.answerPermission(request.id, with: option.optionId) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
            }
        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    static func statusText(_ session: SessionController) -> String {
        if let outcome = session.transcript.worktreeOutcome { return "\(outcome.notice) Read-only." }
        if session.isMerging { return "Merging…" }
        if session.status == .readOnly { return "Saved history · read-only" }
        if session.status == .failed { return "Connection failed · Continue to reconnect" }
        if session.status == .closed { return "Session ended" }
        if let request = session.pendingPermissions.first {
            let count = min(request.options.count, 9)
            let keys = count > 1 ? "⌥⌘1–⌥⌘\(count)" : count == 1 ? "⌥⌘1" : "no options offered"
            return "Waiting for permission · \(keys)"
        }
        if !session.pendingInputs.isEmpty { return "Waiting for input" }
        if session.queuePaused && !session.queuedPrompts.isEmpty { return "Queue paused · ⇧⌘R resumes" }
        return String(describing: session.status).capitalized
    }

    private func send() { submit(.whenReady) }

    private func submit(_ intent: SessionController.SubmissionIntent) {
        guard editingQueueID == nil || intent == .whenReady else { return }
        guard model.restored == nil, !submitting, let owner = model.owner,
            let session = owner.controller, !session.isChangingConfig,
            [.idle, .running, .stopping].contains(session.status),
            hasDraft || (intent != .whenReady && !session.queuedPrompts.isEmpty)
        else { return }
        let text = prompt, files = attachments, editingID = editingQueueID
        model.errorMessage = nil
        submitting = true
        Task {
            defer { submitting = false }
            if let editingID {
                do {
                    try await session.updateQueuedPrompt(editingID, text: text)
                    finishEditing()
                } catch { model.errorMessage = error.localizedDescription }
            } else if await owner.submit(text, attachments: files, intent: intent) {
                // Acceptance is durable; a failed append leaves the composed draft intact.
                prompt = ""
                attachments = []
            }
        }
    }

    private func editQueuedPrompt(_ entry: QueuedPrompt) {
        guard !submitting, editingQueueID == nil else { return }
        savedDraft = (prompt, attachments)
        editingQueueID = entry.id
        prompt = entry.text
        attachments = entry.content.compactMap {
            guard case .resourceLink(let link) = $0, let url = URL(string: link.uri), url.isFileURL else { return nil }
            return url
        }
    }

    private func recallQueuedPrompt() {
        guard prompt.isEmpty, attachments.isEmpty, let entry = model.displayed?.queuedPrompts.last else { return }
        editQueuedPrompt(entry)
    }

    private func finishEditing() {
        prompt = savedDraft?.text ?? ""
        attachments = savedDraft?.attachments ?? []
        editingQueueID = nil
        savedDraft = nil
    }

    static func launchCommand(executable: String, arguments: String) -> (executable: String, arguments: [String]) {
        let path = (executable.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return (path, arguments.split(separator: "\n").map(String.init))
    }
}

#Preview { RootView(sessions: SessionManager()) }
