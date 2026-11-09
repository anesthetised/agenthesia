import AgentRuntime
public import AgenthesiaCore
import AppKit
import Persistence
public import SwiftUI

public struct RootView: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    @State private var model: SessionWindowModel
    /// The window's persisted value: the system restores it after relaunch (ADR-0026).
    @Binding private var target: WindowTarget
    @State private var submitting = false
    @State private var configError: String?
    @State private var showingLog = false
    /// The window's remembered inspector visibility; `SessionWindowModel.showingInspector` is the working copy.
    @SceneStorage("showingInspector") private var storedInspector = true
    /// The window's remembered shelf states; `SessionWindowModel.workingShelfExpanded` and `settledShelfExpanded` are
    /// the working copies.
    @SceneStorage("sidebar.workingExpanded") private var storedWorkingShelf = true
    @SceneStorage("sidebar.settledExpanded") private var storedSettledShelf = false
    @State private var showingQuickOpen = false
    @State private var fileQuery = ""

    public init(
        sessions: SessionManager,
        catalog: AgentCatalog? = nil,
        target: Binding<WindowTarget> = .constant(.launch)
    ) {
        self.init(model: SessionWindowModel(sessions: sessions, catalog: catalog), target: target)
    }

    init(model: SessionWindowModel, target: Binding<WindowTarget> = .constant(.launch)) {
        _model = State(initialValue: model)
        _target = target
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionSidebarColumn(model: model)
                .navigationTitle("Agenthesia")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .toolbar {
                    Button("New Session", systemImage: "plus") { model.showingSetup = true }
                        .disabled(!model.canStart)
                }
        } detail: {
            VStack(spacing: 0) {
                // Stacked, so the draft keeps its size while Send's transition moves its card to the bottom.
                ZStack {
                    if model.inDraft {
                        SessionDraftView(model: model).transition(DraftSendTransition())
                    } else if model.isLoadingHistory {
                        ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let session = model.displayed {
                        GeometryReader { geometry in panes(session, size: geometry.size) }
                    } else {
                        let starting = model.owner?.isStarting == true
                        ContentUnavailableView {
                            Label(
                                starting ? "Starting session…" : "Start a session",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        } description: {
                            if !starting { Text("Choose a project and an installed ACP agent.") }
                        }
                    }
                }
                if model.restored == nil, let diagnostic = model.owner?.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                // Composer errors show above the composer card while it is displayed.
                let composerShown = model.displayed != nil && model.signIn == nil
                if let error = (composerShown ? nil : model.errorMessage)
                    ?? (model.restored == nil ? model.owner?.errorMessage : nil)
                {
                    FailureBanner(error, offering: failureActions, perform: perform).padding()
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
            .navigationTitle(model.windowTitle)
            .navigationSubtitle(model.windowSubtitle)
            .toolbar {
                Button("Quick Open", systemImage: "doc.text.magnifyingglass") {
                    fileQuery = ""
                    model.files.setQuery("")
                    showingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.showingSetup || !filesMatchSession)
                Button(model.showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                    model.showingInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.showingSetup || model.displayed == nil)
                .help("Show or hide the inspector (⌥⌘I)")
                if model.restored == nil, let owner = model.owner {
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
        // Notifications lead back to a session through its URL (ADR-0030).
        .onOpenURL { open($0) }
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        // A session in front of the user needs no notification (ADR-0026).
        .onChange(of: shownSessionID, initial: true) { model.sessions.setShown(shownSessionID, in: model) }
        .onAppear {
            model.showingInspector = storedInspector
            model.workingShelfExpanded = storedWorkingShelf
            model.settledShelfExpanded = storedSettledShelf
        }
        .onChange(of: model.showingInspector) { storedInspector = model.showingInspector }
        .onChange(of: model.workingShelfExpanded) { storedWorkingShelf = model.workingShelfExpanded }
        .onChange(of: model.settledShelfExpanded) { storedSettledShelf = model.settledShelfExpanded }
        .task {
            await model.restore(target)
            target = model.target
        }
        // A session started from the draft that fails or is cancelled returns its draft (ADR-0040).
        .task(id: model.abandonedStart?.id) { await model.returnToDraft() }
        .onChange(of: model.target) { target = model.target }
        .task(id: model.filesSession?.id) { await model.files.attach(model.filesSession) }
        .onChange(of: model.displayed?.fileRevision) { model.files.invalidate() }
        .onChange(of: model.displayed?.session.id) {
            model.dropStaleQueueEdit(); model.closeFind(); showingQuickOpen = false; fileQuery = ""
            model.review = nil; model.showingReview = false
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
        .sheet(item: $model.signInTerminal) { terminal in
            SignInTerminalSheet(terminal: terminal) { model.signInTerminal = nil }
        }
        .sheet(item: $model.merge) { request in
            MergeSheet(request: request) { Task { await model.confirmMerge(request) } }
        }
    }

    private struct HistoryKey: Equatable {
        let owners: [UUID?]
        let discarding: Set<UUID>
        let merging: Set<UUID>
    }

    private func open(_ url: URL) {
        guard let opened = WindowTarget(url: url) else { return }
        let windows = NSApp.windows.count { $0.isVisible && $0.canBecomeMain }
        Task {
            await model.activate(opened, isBlank: model.draft.isEmpty, windowCount: windows) { openWindow(value: $0) }
            target = model.target
        }
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

    /// The transcript, the file pane or the review pane, and the inspector side by side. Widths are computed from
    /// the column's width (`DetailPanes`) instead of an `HSplitView`, whose split view kept stale divider positions
    /// when a pane appeared or the window shrank (ADR-0039, amendment 2026-10-30).
    private func panes(_ session: SessionController, size: CGSize) -> some View {
        let width = size.width
        let review = model.isReviewShown ? model.review : nil
        let panes = DetailPanes(
            width: width,
            filePane: review != nil || (filesMatchSession && model.files.selectedPath != nil),
            inspector: model.showingInspector
        )
        let widths = panes.widths(
            filePane: review != nil ? model.reviewWidth : model.filePaneWidth,
            inspector: model.inspectorWidth
        )
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                // A finished turn's Done mark clears once its end was on screen in an active window.
                LiveTranscript(
                    session: session,
                    pathIndex: pathIndex(for: session),
                    originLabel: model.sessions.originLabel,
                    find: model.find,
                    unseenResult: model.unseenResult(appearsActive: appearsActive),
                    onResultShown: { [weak owner = model.owner] in owner?.markSeen(reaching: $0) },
                    jumpRequests: model.jumpRequests,
                    onPositionChange: { [weak model] in model?.endPosition = $0 }
                ) {
                    openFile($0.path, line: $0.line, for: $1)
                }
                .id(session.session.id)
                .overlay(alignment: .topTrailing) {
                    if model.find.isOpen { TranscriptFindBar(model: model) }
                }
                .overlay(alignment: .bottom) {
                    if model.endPosition == .newBelow { NewResponseButton(action: model.jumpToLatest) }
                }
                if let signIn = model.signIn {
                    SignInPanel(
                        agentName: model.owner?.agentName ?? "the agent",
                        signIn: signIn,
                        continuing: session.session.agentSessionID != nil,
                        onSignIn: model.signIn(with:),
                        onCancel: model.cancelSignIn
                    )
                } else {
                    composer(session, height: size.height)
                }
            }.frame(width: widths.transcript)
            if panes.showsFilePane {
                Group {
                    if let review {
                        SessionReviewPane(review: review, files: model.files, model: model, height: size.height)
                    } else {
                        SessionFilePane(files: model.files) { openFile($0, line: $1, for: $2) }
                    }
                }
                .frame(width: widths.filePane)
                .overlay(alignment: .leading) {
                    PaneDivider(width: widths.filePane) {
                        let width = max($0, DetailPanes.filePaneMinWidth)
                        if review != nil { model.reviewWidth = width } else { model.filePaneWidth = width }
                    }
                }
            }
            if panes.showsInspector {
                SessionInspector(model: model, showingLog: $showingLog) { openFile($0, for: $1) }
                    .frame(width: widths.inspector)
                    .overlay(alignment: .leading) {
                        PaneDivider(width: widths.inspector) {
                            model.inspectorWidth = min(
                                max($0, DetailPanes.inspectorMinWidth),
                                DetailPanes.inspectorMaxWidth
                            )
                        }
                    }
            }
        }
        .frame(width: width)
    }

    /// What a failure banner can do here. Reconnecting is the Continue card's button, so the banner has no Retry.
    private let failureActions: Set<SessionFailure.Action> = [.agentLog, .newSession, .manageAgents]

    private func perform(_ action: SessionFailure.Action) {
        switch action {
        case .agentLog: showingLog = true
        case .newSession: model.showingSetup = true
        case .manageAgents: break  // A Settings link in the banner.
        }
    }

    private func openFile(_ path: String, line: Int? = nil, for id: UUID?) {
        guard let id, model.displayed?.session.id == id, model.files.sessionID == id else { return }
        showingQuickOpen = false
        // The file takes the slot; the review keeps its state for ⌃⌘R (ADR-0041).
        model.showingReview = false
        Task {
            guard model.displayed?.session.id == id, !model.closed else { return }
            await model.files.open(path: path, line: line, in: id)
        }
    }

    /// The docked permission card, failures, the status line, and the composer card or the Continue card; `height` is
    /// the column's.
    private func composer(_ session: SessionController, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PermissionDock(session: session, maxHeight: 0.4 * height)
            if let error = model.errorMessage ?? configError {
                FailureBanner(error, offering: failureActions, perform: perform)
            }
            if let startedAt = session.turnStartedAt {
                WorkingTimeLine(
                    startedAt: startedAt,
                    waiting: !session.pendingPermissions.isEmpty || !session.pendingInputs.isEmpty
                )
            }
            if let card = ContinueCard.State(
                status: session.status,
                isMerging: session.isMerging,
                outcome: model.outcome(of: session.session.id),
                canContinue: model.canContinue
            ) {
                // What Continue brings back (ADR-0039): the retained queue and the last confirmed settings.
                if card.showsContinue, !session.queuedPrompts.isEmpty {
                    PromptQueue(
                        session: session,
                        editable: false,
                        caption: "Queued · sent after Continue",
                        onEdit: { _ in },
                        onError: { _ in }
                    )
                }
                ContinueCard(
                    state: card,
                    settings: card.showsContinue ? ContinueCard.settingsLine(session.transcript.configOptions) : nil,
                    onContinue: model.continueRestored
                )
            } else {
                editorCard(session)
            }
        }
        .frame(maxWidth: TranscriptColumn.maxWidth)
        .padding(.horizontal, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func editorCard(_ session: SessionController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.queuedPrompts.isEmpty {
                PromptQueue(
                    session: session,
                    editable: !submitting,
                    onEdit: editQueuedPrompt,
                    onError: { model.errorMessage = $0.localizedDescription }
                )
            }
            if model.composer.editingQueueID != nil {
                HStack {
                    Text("Editing queued message · Return saves").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Edit") { model.composer.finishEditing() }
                }
            }
            ComposerInput(
                text: Bindable(model).composer.message.text,
                attachments: Bindable(model).composer.message.attachments,
                commands: session.transcript.commands,
                isEnabled: !submitting,
                onSubmit: submit,
                attachmentsEditable: model.composer.editingQueueID == nil,
                onRecall: recallQueuedPrompt,
                onStop: { Task { await model.stop() } },
                focusRequests: model.composerFocusRequests,
                insertion: model.composerInsertion
            )
            composerControls(session)
        }
        .padding(12)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.composer.editingQueueID == nil, !submitting else { return false }
            ComposerInput.add(urls, to: &model.composer.message.attachments)
            return true
        }
    }

    /// The card's bottom row: attach and the session's settings, then the round Send/Stop button.
    private func composerControls(_ session: SessionController) -> some View {
        HStack(spacing: 8) {
            Button("Attach Files…", systemImage: "paperclip", action: chooseAttachments)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Attach files or folders (⇧⌘A)").disabled(model.composer.editingQueueID != nil || submitting)
            SessionConfigControls(session: session, onError: { configError = $0 }).id(session.session.id)
                .frame(maxWidth: .infinity, alignment: .leading)
            let turnActive =
                session.status == .running || session.status == .stopping || !session.pendingInputs.isEmpty
            let action = ComposerPrimaryAction(
                turnActive: turnActive,
                hasDraft: hasDraft,
                editingQueued: model.composer.editingQueueID != nil,
                idleWithEmptyQueue: session.status == .idle && session.queuedPrompts.isEmpty
            )
            Menu("Send options", systemImage: "chevron.down") {
                Button(ComposerPrimaryAction.sendNowTitle(hasDraft: hasDraft, turnActive: turnActive)) {
                    submit(.now)
                }.keyboardShortcut(
                    .return,
                    modifiers: .command
                )
                .disabled(
                    (!hasDraft && session.queuedPrompts.isEmpty) || submitting || model.composer.editingQueueID != nil
                        || session.isChangingConfig
                )
                Button("Send Whole Queue Now") { submit(.allNow) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(
                        (!hasDraft && session.queuedPrompts.isEmpty) || submitting
                            || model.composer.editingQueueID != nil
                            || session.isChangingConfig
                    )
                if model.canStop {
                    Divider()
                    Button("Stop Turn") { Task { await model.stop() } }
                }
            }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button {
                if action == .stop { Task { await model.stop() } } else { send() }
            } label: {
                if action.showsTitle {
                    Label(action.title, systemImage: action.symbol)
                } else {
                    Label(action.title, systemImage: action.symbol).labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(action.showsTitle ? .capsule : .circle)
            .help(action.help)
            .disabled(
                action == .stop
                    ? session.status == .stopping && session.queuePaused
                    : !hasDraft || submitting || session.isChangingConfig
            )
        }
    }

    private var hasDraft: Bool {
        !model.composer.message.isEmpty
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.owner?.workingDirectory
        if panel.runModal() == .OK { ComposerInput.add(panel.urls, to: &model.composer.message.attachments) }
    }

    private func send() { submit(.whenReady) }

    private func submit(_ intent: SessionController.SubmissionIntent) {
        guard model.composer.editingQueueID == nil || intent == .whenReady else { return }
        guard model.restored == nil, !submitting, let owner = model.owner,
            let session = owner.controller, !session.isChangingConfig,
            [.idle, .running, .stopping].contains(session.status),
            hasDraft || (intent != .whenReady && !session.queuedPrompts.isEmpty)
        else { return }
        let id = session.session.id
        let draft = model.composer
        model.errorMessage = nil
        submitting = true
        Task {
            defer { submitting = false }
            if let editingID = draft.editingQueueID {
                do {
                    try await session.updateQueuedPrompt(editingID, text: draft.message.text)
                    model.composerDrafts[id]?.finishEditing()
                } catch { model.errorMessage = error.localizedDescription }
            } else if await owner.submit(draft.message.text, attachments: draft.message.attachments, intent: intent) {
                // Acceptance is durable; a failed append leaves the composed draft intact. The window may show another
                // session by now, so this clears the draft that was sent.
                model.composerDrafts[id] = nil
            }
        }
    }

    private func editQueuedPrompt(_ entry: QueuedPrompt) {
        guard !submitting, model.composer.editingQueueID == nil else { return }
        model.composer.edit(entry)
    }

    private func recallQueuedPrompt() {
        guard model.composer.message == PromptDraft(), let entry = model.displayed?.queuedPrompts.last else { return }
        editQueuedPrompt(entry)
    }

    static func launchCommand(executable: String, arguments: String) -> (executable: String, arguments: [String]) {
        let path = (executable.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return (path, arguments.split(separator: "\n").map(String.init))
    }
}

#Preview { RootView(sessions: SessionManager()) }
