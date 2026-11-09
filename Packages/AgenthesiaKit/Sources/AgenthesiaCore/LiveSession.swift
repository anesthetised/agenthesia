public import ACP
import AgentRuntime
public import Foundation
import JSONRPC
import Observation
public import Persistence
import Workspace

/// One agent connection, owned by `SessionManager` (ADR-0026). Close on End Session or app quit;
/// worktrees remain on disk, except one made for a new session that never got a history record.
@MainActor @Observable
public final class LiveSession {
    public private(set) var controller: SessionController?
    public private(set) var isStarting = false
    public private(set) var isClosed = false
    public private(set) var errorMessage: String?
    public private(set) var diagnostic: String?
    public private(set) var stderrLog = ""
    public private(set) var workingDirectory: URL?
    /// The saved session this owner continues, known before its controller exists.
    public private(set) var resuming: SessionRecord?
    /// Set while the agent waits for the user to sign in (ADR-0033).
    public private(set) var signIn: SignIn?
    /// A terminal sign-in method's command, while it runs and after it fails.
    public private(set) var signInTerminal: SignInTerminal?
    /// The draft a new session was started with (ADR-0040), held until it is submitted at the first idle state.
    /// It stays when startup fails or is cancelled, so the window can return it to the draft.
    public private(set) var initialPrompt: PromptDraft?
    /// Runs once the initial prompt was submitted, e.g. to remember the agent the session started with.
    @ObservationIgnored public var onInitialPromptSubmitted: (() -> Void)?
    /// The configured agent's name, once its install is known.
    public var agentName: String? { agent?.name }
    /// Labels a turn the user did not send (ADR-0049); `SessionManager` names the source session.
    @ObservationIgnored public var originLabel: (QueuedPrompt.Origin) -> String? = { $0.label(title: nil, agent: nil) }
    /// Turns finished when the user last saw a result on screen (ADR-0026's amendment). In memory only.
    private var seenTurns = 0
    @ObservationIgnored private let library: SessionLibrary
    @ObservationIgnored private var process: AgentProcess?
    @ObservationIgnored private var connection: ACP.V1.AgentConnectionAdapter?
    @ObservationIgnored private var agent: AgentInstallRecord?
    /// The agent's command and environment, without a working directory; chat and sign-in both run it.
    @ObservationIgnored private var agentCommand: AgentCommand?
    /// Keeps an installed version in place until the agent's processes have exited (ADR-0036).
    @ObservationIgnored private var lease: AgentInstaller.Lease?
    @ObservationIgnored private var signInCancelled = false
    @ObservationIgnored private(set) var startup: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    /// Where attached files from the user's checkout are found in the session worktree (ADR-0018).
    @ObservationIgnored private var checkout: (checkout: URL, worktree: URL)?
    /// The worktree this owner created for a new session, until it is removed or found to have a record.
    @ObservationIgnored private var created: (id: UUID, worktree: SessionWorkspace.Worktree, baseRevision: String)?
    /// The folder this owner created for a new session without a project (ADR-0048), until it is removed or found to
    /// have a record.
    @ObservationIgnored private var createdScratch: (id: UUID, folder: URL)?
    /// Keeps the agent's confirmed mode and model as the next draft's hints (ADR-0040) and whether its start met
    /// sign-in; set by `SessionManager`.
    @ObservationIgnored var catalog: AgentCatalog?
    // Test seam for a suspended environment lookup; production shares the login-shell resolver.
    @ObservationIgnored var environment = LiveSession.shellEnvironment

    /// The login shell's environment, shared by agent launches and merge commits.
    static let shellEnvironment: @Sendable () async -> (values: [String: String], diagnostic: String?) = {
        let resolution = await ShellEnvironment.shared.resolve()
        return (resolution.environment, resolution.diagnostic)
    }

    public init(library: SessionLibrary = .shared) { self.library = library }

    /// What the sidebar shows for this session.
    public var activity: Activity {
        Activity.derive(
            starting: isStarting,
            failed: errorMessage != nil && !isLive,
            status: controller?.status,
            needsInput: signIn != nil
                || controller.map { !$0.pendingPermissions.isEmpty || !$0.pendingInputs.isEmpty } ?? false,
            unseen: hasUnseenResult
        )
    }

    /// The sidebar's second-line reason for ``activity`` (ADR-0039); nil when the symbol says it all.
    public var reason: String? {
        let activity = activity
        return SidebarReason.text(
            activity: activity,
            signIn: signIn != nil,
            permissionTitles: controller?.pendingPermissions.map(\.callTitle) ?? [],
            starting: isStarting || controller?.status == .starting,
            stopping: controller?.status == .stopping,
            merging: controller?.isMerging == true,
            stopReason: controller?.transcript.lastStopReason,
            promptFailed: controller?.transcript.lastTurnFailed == true,
            queuePaused: controller.map { $0.queuePaused && !$0.queuedPrompts.isEmpty } == true,
            turnOrigin: controller.flatMap { originLabel($0.transcript.turnOrigin) },
            planStep: PlanProgress(controller?.transcript.plan)?.current
        )
    }

    /// A turn ended since the user last looked at the session.
    public var hasUnseenResult: Bool { (controller?.completedTurns ?? 0) > seenTurns }

    /// Where the latest finished turn ends, while the user has not seen it; the transcript watches for it.
    public var unseenResult: Int64? { hasUnseenResult ? controller?.lastResultItem : nil }

    /// Marks every finished turn seen.
    public func markSeen() { seenTurns = controller?.completedTurns ?? 0 }

    /// The end of `item` was on screen; that sees every finished turn only when it is the latest result.
    public func markSeen(reaching item: Int64) {
        if item == controller?.lastResultItem { markSeen() }
    }

    public var sessionID: UUID? { controller?.session.id ?? resuming?.id }

    /// Whether the agent is starting or connected; false once closed or failed.
    public var isLive: Bool {
        !isClosed
            && (isStarting || signIn != nil
                || controller.map { [.idle, .running, .stopping].contains($0.status) } == true)
    }

    /// A nil `directory` starts without a project, in a new folder under `scratchRoot` (ADR-0048).
    public func start(
        directory: URL?,
        agent: AgentInstallRecord,
        worktreesRoot: URL? = nil,
        scratchRoot: URL? = nil,
        additionalDirectories: [URL] = [],
        initialPrompt: PromptDraft? = nil,
        configHints: [ACP.ConfigOption] = []
    ) async {
        begin(
            .new(
                directory: directory,
                agent: agent,
                worktreesRoot: worktreesRoot,
                scratchRoot: scratchRoot,
                additionalDirectories: additionalDirectories,
                configHints: configHints
            ),
            initialPrompt: initialPrompt
        )
        await startup?.value
    }

    /// Continues a saved session in its working directory with its agent (ADR-0017).
    public func resume(_ session: SessionRecord) async {
        begin(.saved(session))
        await startup?.value
    }

    enum Launch {
        /// A nil `directory` is a session without a project.
        case new(
            directory: URL?,
            agent: AgentInstallRecord,
            worktreesRoot: URL?,
            scratchRoot: URL? = nil,
            additionalDirectories: [URL],
            configHints: [ACP.ConfigOption] = []
        )
        case saved(SessionRecord)
    }

    /// Starts launching without waiting, after the earlier owners of the same session have closed.
    func begin(_ launch: Launch, after previous: [LiveSession] = [], initialPrompt: PromptDraft? = nil) {
        guard startup == nil, controller == nil, !isClosed else { return }
        if case .saved(let session) = launch { resuming = session }
        self.initialPrompt = initialPrompt
        isStarting = true
        startup = Task {
            for owner in previous { await owner.close() }
            await self.launch(launch)
        }
    }

    private func launch(_ launch: Launch) async {
        defer { isStarting = false }
        do {
            let store = try await library.store()
            guard !isClosed else { return }
            let agent: AgentInstallRecord
            switch launch {
            case .new(_, let new, _, _, _, _): agent = new
            case .saved(let session):
                guard let install = try await library.install(id: session.agentInstallID) else {
                    throw LaunchError(message: "The agent of this session is no longer configured.")
                }
                agent = install
            }
            self.agent = agent
            // Resolve and check the command first, so a mistyped executable does not leave a worktree behind.
            if let installationID = agent.installationID {
                try await acquire(installationID, name: agent.name)
            } else {
                let resolution = await environment()
                diagnostic = resolution.diagnostic
                agentCommand = AgentCommand(
                    executable: agent.executable,
                    arguments: agent.arguments,
                    environment: resolution.values
                )
                guard !isClosed else { return }
                guard Self.isExecutable(agent.executable, path: resolution.values["PATH"]) else {
                    throw LaunchError(message: "Cannot find an executable named “\(agent.executable)”.")
                }
            }
            guard !isClosed else { return }
            let controller: SessionController
            switch launch {
            case .new(let directory, _, let worktreesRoot, let scratchRoot, let additionalDirectories, let configHints):
                controller = try await create(
                    directory: directory,
                    agent: agent,
                    worktreesRoot: worktreesRoot,
                    scratchRoot: scratchRoot,
                    additionalDirectories: additionalDirectories,
                    configHints: configHints,
                    store: store
                )
            case .saved(let session):
                controller = try await SessionController.history(id: session.id, store: store)
                if let outcome = controller.transcript.worktreeOutcome {
                    throw LaunchError(message: "\(outcome.notice) The session cannot continue.")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.workingDirectory, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw LaunchError(message: "The working directory “\(session.workingDirectory)” no longer exists.")
                }
                workingDirectory = URL(filePath: session.workingDirectory)
            }
            guard !isClosed else { return }
            checkout = await SessionWorkspace.linkedCheckout(of: URL(filePath: controller.session.workingDirectory))
            guard !isClosed else { return }
            self.controller = controller
            controller.onConfigOptions = { [weak self] options in
                guard let self, let agent = self.agent else { return }
                self.catalog?.rememberHints(options, for: agent)
            }
            controller.fileSystem = try await SessionFileSystem(controller: controller)
            guard !isClosed else { await controller.close(); return }
            try await connect()
        } catch {
            await fail(error)
        }
    }

    /// Leases the installed version, which also checks its files and its saved Node runtime.
    private func acquire(_ installationID: UUID, name: String) async throws {
        let installer = library.installer
        guard let installation = try await installer.installations().first(where: { $0.id == installationID }) else {
            throw LaunchError(
                message:
                    "The version of \(name) this session used is no longer installed. Install it again in Settings → Agents, or start a new session."
            )
        }
        let lease = try await installer.acquire(
            installation,
            directory: FileManager.default.homeDirectoryForCurrentUser
        )
        guard !isClosed else { lease.release(); return }
        self.lease = lease
        diagnostic = lease.shellDiagnostic
        agentCommand = lease.command
    }

    /// Launches the agent and starts or reopens the session. When the agent asks for sign-in, the session
    /// waits for it with the agent still running; `afterSignIn` says that an attempt has just ended.
    private func connect(afterSignIn: Bool = false) async throws {
        guard let controller, var command = agentCommand else { return }
        command.currentDirectory = URL(filePath: controller.session.workingDirectory)
        let process = try await Task.detached { try AgentProcess(launching: command) }.value
        self.process = process
        guard !isClosed else { await cleanup(); return }
        logTask?.cancel()
        logTask = Task { [weak self] in
            for await _ in process.stderr {
                let log = await process.stderrLog
                self?.stderrLog = log
            }
        }
        let connection = await ACP.V1.AgentConnectionAdapter(
            transport: process.transport,
            delegate: controller,
            fileSystem: controller.fileSystem,
            options: .init(terminalAuth: true, elicitation: true)
        )
        self.connection = connection
        guard !isClosed else { await connection.close(); await cleanup(); return }
        let client = ACP.Implementation(name: "Agenthesia", version: "0.1")
        do {
            if controller.session.agentSessionID != nil {
                try await controller.reopen(connection: connection, client: client)
            } else {
                try await controller.start(connection: connection, client: client)
            }
        } catch SessionController.SessionError.authenticationRequired {
            requireSignIn(again: afterSignIn)
            return
        }
        try await connected(process)
    }

    private func requireSignIn(again: Bool) {
        guard !isClosed else { return }
        if let agent { catalog?.setSignInNeeded(true, for: agent) }
        signIn = SignIn(
            methods: controller?.profile?.authMethods ?? [],
            pending: signIn?.pending,
            message: again ? "\(agent?.name ?? "The agent") still requires sign-in." : nil
        )
    }

    /// The session is idle for the first time: the initial prompt goes in like a typed one. A failed submission
    /// fails the startup, which returns the draft.
    private func connected(_ process: AgentProcess) async throws {
        guard !isClosed else { return }
        signIn = nil
        if let agent { catalog?.setSignInNeeded(false, for: agent) }
        observeFailure()
        exitTask = Task { [weak self] in
            let status = await process.waitForExit()
            await process.waitForStderr()
            guard let self, !self.isClosed else { return }
            self.stderrLog = await process.stderrLog
            self.errorMessage =
                self.controller?.errorMessage ?? "The agent \(status). Continue to reconnect."
            await self.controller?.close()
            await self.cleanup()
        }
        guard let initialPrompt, let controller else { return }
        try await controller.submit(
            Self.content(initialPrompt.text, attachments: initialPrompt.attachments, checkout: checkout)
        )
        self.initialPrompt = nil
        onInitialPromptSubmitted?()
        onInitialPromptSubmitted = nil
    }

    private func fail(_ error: any Error) async {
        if !isClosed {
            errorMessage =
                error as? SessionController.SessionError == .cannotReopen
                ? "\(agent?.name ?? "The agent") cannot continue saved sessions."
                : controller?.errorMessage ?? error.localizedDescription
        }
        signIn = nil
        signInTerminal = nil
        await controller?.close()
        await cleanup()
        await removeUnstartedWorktree()
    }

    /// Removes the worktree and branch, or the empty folder of a session without a project, this owner created when
    /// no history record refers to them, since a start that failed or was cancelled never happened (ADR-0040,
    /// ADR-0048). The record is written once the agent accepts `session/new`, so the store decides. Anything
    /// unexpected leaves the files in place; the user is only cancelling a start.
    private func removeUnstartedWorktree() async {
        if let (id, folder) = createdScratch {
            createdScratch = nil
            do {
                guard try await library.store().session(id: id) == nil else { return }
                if try await SessionWorkspace.removeEmptyScratch(folder) { workingDirectory = nil }
            } catch {}
        }
        guard let (id, worktree, baseRevision) = created else { return }
        created = nil
        do {
            guard try await library.store().session(id: id) == nil else { return }
            if try await SessionWorkspace.removeUntouched(worktree, baseRevision: baseRevision) {
                workingDirectory = nil
            }
        } catch {}
    }

    /// Signs in with one of the agent's methods, then starts or continues the session (ADR-0033). An agent
    /// method authenticates the open connection; a terminal method runs in `signInTerminal`, and the agent is
    /// launched again after it exits with status 0.
    public func signIn(with id: ACP.AuthMethodID) async {
        guard var state = signIn, state.pending == nil, !isClosed,
            let method = state.methods.first(where: { $0.id == id })
        else { return }
        state.pending = id
        state.message = nil
        signIn = state
        signInCancelled = false
        signInTerminal = nil
        do {
            switch method {
            case .agent: try await authenticate(id)
            case .terminal(let terminal): try await signIn(on: terminal)
            case .unknown: signIn?.message = "Agenthesia does not support this sign-in method."
            }
        } catch {
            if !isClosed { await fail(error) }
        }
        signIn?.pending = nil
    }

    private func authenticate(_ id: ACP.AuthMethodID) async throws {
        if connection == nil {
            // An earlier attempt shut the agent down.
            try await connect()
        }
        guard signIn != nil, let connection, let controller, let process, !isClosed else { return }
        do {
            try await connection.authenticate(methodId: id)
        } catch let error as RPCError {
            if !signInCancelled { signIn?.message = error.message }
            return
        } catch {
            await shutDownAgent()
            if !signInCancelled, !isClosed { signIn?.message = "\(agent?.name ?? "The agent") exited during sign-in." }
            return
        }
        guard !isClosed else { return }
        do {
            try await controller.retry()
        } catch SessionController.SessionError.authenticationRequired {
            requireSignIn(again: true)
            return
        }
        try await connected(process)
    }

    private func signIn(on method: ACP.TerminalAuthMethod) async throws {
        guard var command = agentCommand, let controller else { return }
        await shutDownAgent()
        guard !isClosed else { return }
        command.arguments += method.args ?? []
        command.environment = (command.environment ?? [:]).merging(method.env ?? [:]) { $1 }
        command.environment?["TERM"] = "xterm-256color"
        command.currentDirectory = URL(filePath: controller.session.workingDirectory)
        let process: TerminalProcess
        do {
            process = try await Task.detached { try TerminalProcess(launching: command) }.value
        } catch {
            signIn?.message = "Cannot run the sign-in command: \(error.localizedDescription)"
            return
        }
        let terminal = SignInTerminal(title: method.name, process: process)
        signInTerminal = terminal
        if isClosed || signInCancelled { await terminal.terminate() }
        let status = await terminal.waitForExit()
        guard !isClosed, !signInCancelled else {
            if signInTerminal === terminal { signInTerminal = nil }
            return
        }
        guard status == .exited(0) else { return }
        signInTerminal = nil
        try await connect(afterSignIn: true)
    }

    /// Stops the sign-in attempt in progress; the session keeps waiting for sign-in.
    public func cancelSignIn() async {
        guard signIn?.pending != nil else { return }
        signInCancelled = true
        if let signInTerminal, signInTerminal.exitMessage == nil {
            await signInTerminal.terminate()
        } else {
            await shutDownAgent()
        }
    }

    /// Hides a terminal sign-in that has failed.
    public func dismissSignInTerminal() {
        guard signInTerminal?.exitMessage != nil else { return }
        signInTerminal = nil
    }

    /// Closes the connection and stops the agent, so that the next attempt launches it again.
    private func shutDownAgent() async {
        let connection = connection
        self.connection = nil
        await connection?.close()
        await cleanup(releasingLease: false)
        process = nil
    }

    private func create(
        directory: URL?,
        agent: AgentInstallRecord,
        worktreesRoot: URL?,
        scratchRoot: URL?,
        additionalDirectories: [URL],
        configHints: [ACP.ConfigOption],
        store: PersistenceStore
    ) async throws -> SessionController {
        let id = UUID()
        let worktreesRoot = worktreesRoot ?? SessionWorkspace.defaultWorktreesRoot
        let topic = initialPrompt.flatMap { SessionTitle.fromPrompt($0.text) }
        let workspace: SessionWorkspace
        if let directory {
            workspace = try await SessionWorkspace.prepare(
                directory: directory,
                id: id,
                topic: topic,
                worktreesRoot: worktreesRoot,
                // The agent's login-shell environment, resolved once for this launch.
                environment: agentCommand?.environment
            )
        } else {
            workspace = try await SessionWorkspace.prepareScratch(
                id: id,
                topic: topic,
                scratchRoot: scratchRoot ?? SessionWorkspace.defaultScratchRoot
            )
            createdScratch = (id, workspace.workingDirectory)
        }
        workingDirectory = workspace.workingDirectory
        if let baseRevision = workspace.baseRevision,
            let worktree = SessionWorkspace.Worktree(
                projectDirectory: workspace.projectDirectory,
                workingDirectory: workspace.workingDirectory,
                sessionID: id,
                branch: workspace.branch,
                worktreesRoot: worktreesRoot
            )
        {
            created = (id, worktree, baseRevision)
        }
        guard !isClosed else { throw CancellationError() }
        let project = try await library.project(
            directory: workspace.projectDirectory,
            name: directory == nil ? ProjectRecord.scratchName : nil
        )
        let install = try await library.install(agent)
        guard !isClosed else { throw CancellationError() }
        return SessionController(
            session: SessionRecord(
                id: id,
                projectID: project.id,
                agentInstallID: install.id,
                workingDirectory: workspace.workingDirectory.path,
                baseRevision: workspace.baseRevision,
                baseBranch: workspace.baseBranch,
                branch: workspace.branch,
                fallbackUpstream: workspace.fallbackUpstream
            ),
            store: store,
            additionalDirectories: additionalDirectories.map { $0.path(percentEncoded: false) },
            configHints: configHints
        )
    }

    /// Sends the text followed by a `resource_link` per attached file.
    public func send(_ text: String, attachments: [URL] = []) async {
        guard let controller, !isClosed else { return }
        let content = Self.content(text, attachments: attachments, checkout: checkout)
        do { try await controller.send(content) } catch {
            if !isClosed { errorMessage = controller.errorMessage ?? error.localizedDescription }
            if controller.status == .failed { await cleanup() }
        }
    }

    /// Accepts a draft into the durable queue or starts a turn, reporting whether it was accepted.
    @discardableResult public func submit(
        _ text: String,
        attachments: [URL] = [],
        intent: SessionController.SubmissionIntent = .whenReady
    ) async -> Bool {
        guard let controller, !isClosed else { return false }
        let content = Self.content(text, attachments: attachments, checkout: checkout)
        do {
            try await controller.submit(content, intent: intent)
            errorMessage = nil
            return true
        } catch {
            if !isClosed { errorMessage = controller.errorMessage ?? error.localizedDescription }
            if controller.status == .failed { await cleanup() }
            return false
        }
    }

    static func content(
        _ text: String,
        attachments: [URL],
        checkout: (checkout: URL, worktree: URL)?
    ) -> [ACP.ContentBlock] {
        let links = attachments.map { ACP.ContentBlock.resourceLink(.file($0, checkout: checkout)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !links.isEmpty
            ? links : [.init(text: text)] + links
    }

    public func stop() async {
        do { try await controller?.stop() } catch {
            errorMessage = controller?.errorMessage ?? error.localizedDescription
            await cleanup()
        }
    }

    public func close() async {
        if let closing { await closing.value; return }
        isClosed = true
        signIn = nil
        let task = Task {
            await signInTerminal?.terminate()
            await controller?.close()
            await cleanup()
            await startup?.value
            // Startup may have been awaiting Process.run when close began.
            await controller?.close()
            await cleanup()
            await exitTask?.value
            await removeUnstartedWorktree()
        }
        closing = task
        await task.value
    }

    struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Mirrors `AgentProcess`: a path is used as is, a bare name is looked up in the agent's `PATH`.
    static func isExecutable(_ executable: String, path: String?) -> Bool {
        if executable.contains("/") { return FileManager.default.isExecutableFile(atPath: executable) }
        return (path ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: URL(filePath: String($0)).appending(path: executable).path)
        }
    }

    /// Stops the agent. The lease goes too unless the agent is about to be launched again for sign-in.
    private func cleanup(releasingLease: Bool = true) async {
        if let process {
            _ = await process.terminate()
            await process.waitForStderr()
            stderrLog = await process.stderrLog
            logTask?.cancel()
            logTask = nil
        }
        // Close terminates a terminal sign-in, which also runs the leased command, before this.
        guard releasingLease else { return }
        lease?.release()
        lease = nil
    }

    private func observeFailure() {
        guard !isClosed, let controller else { return }
        withObservationTracking {
            _ = controller.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if self.controller?.status == .failed {
                    self.errorMessage = self.controller?.errorMessage
                    await self.cleanup()
                } else {
                    self.observeFailure()
                }
            }
        }
    }
}

extension LiveSession: Identifiable {}
