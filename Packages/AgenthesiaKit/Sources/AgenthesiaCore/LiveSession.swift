import ACP
import AgentRuntime
public import Foundation
import Observation
public import Persistence
import Workspace

/// Window-bound owner. Close explicitly on window close or app quit; worktrees remain on disk.
@MainActor @Observable
public final class LiveSession {
    public private(set) var controller: SessionController?
    public private(set) var isStarting = false
    public private(set) var isClosed = false
    public private(set) var errorMessage: String?
    public private(set) var diagnostic: String?
    public private(set) var stderrLog = ""
    public private(set) var workingDirectory: URL?
    @ObservationIgnored private let library: SessionLibrary
    @ObservationIgnored private var process: AgentProcess?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    /// The session this owner holds in the library, released on cleanup.
    @ObservationIgnored private var claimed: UUID?
    /// Where attached files from the user's checkout are found in the session worktree (ADR-0018).
    @ObservationIgnored private var checkout: (checkout: URL, worktree: URL)?
    // Test seam for a suspended environment lookup; production shares the login-shell resolver.
    @ObservationIgnored var environment: @Sendable () async -> (values: [String: String], diagnostic: String?) = {
        let resolution = await ShellEnvironment.shared.resolve()
        return (resolution.environment, resolution.diagnostic)
    }

    public init(library: SessionLibrary = .shared) { self.library = library }

    public func start(
        directory: URL,
        agent: AgentInstallRecord,
        worktreesRoot: URL? = nil,
        additionalDirectories: [URL] = []
    ) async {
        await run(
            .new(
                directory: directory,
                agent: agent,
                worktreesRoot: worktreesRoot,
                additionalDirectories: additionalDirectories
            )
        )
    }

    /// Continues a saved session in its working directory with its agent (ADR-0017).
    public func resume(_ session: SessionRecord) async {
        await run(.saved(session))
    }

    private enum Launch {
        case new(directory: URL, agent: AgentInstallRecord, worktreesRoot: URL?, additionalDirectories: [URL])
        case saved(SessionRecord)
    }

    private func run(_ launch: Launch) async {
        guard startup == nil, controller == nil, !isClosed else { return }
        isStarting = true
        let task = Task { await self.launch(launch) }
        startup = task
        await task.value
    }

    private func launch(_ launch: Launch) async {
        defer { isStarting = false }
        var agentName = "The agent"
        do {
            let store = try await library.store()
            guard !isClosed else { return }
            let agent: AgentInstallRecord
            switch launch {
            case .new(_, let new, _, _): agent = new
            case .saved(let session):
                guard let install = try await library.install(id: session.agentInstallID) else {
                    throw LaunchError(message: "The agent of this session is no longer configured.")
                }
                agent = install
            }
            agentName = agent.name
            // Resolve and check the command first, so a mistyped executable does not leave a worktree behind.
            let resolution = await environment()
            diagnostic = resolution.diagnostic
            guard !isClosed else { return }
            guard Self.isExecutable(agent.executable, path: resolution.values["PATH"]) else {
                throw LaunchError(message: "Cannot find an executable named “\(agent.executable)”.")
            }
            let controller: SessionController
            switch launch {
            case .new(let directory, _, let worktreesRoot, let additionalDirectories):
                controller = try await create(
                    directory: directory,
                    agent: agent,
                    worktreesRoot: worktreesRoot,
                    additionalDirectories: additionalDirectories,
                    store: store
                )
            case .saved(let session):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.workingDirectory, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw LaunchError(message: "The working directory “\(session.workingDirectory)” no longer exists.")
                }
                guard await library.claim(session.id) else {
                    throw LaunchError(message: "This session is already open in another window.")
                }
                claimed = session.id
                workingDirectory = URL(filePath: session.workingDirectory)
                controller = try await SessionController.history(id: session.id, store: store)
            }
            guard !isClosed else { return }
            checkout = await SessionWorkspace.linkedCheckout(of: URL(filePath: controller.session.workingDirectory))
            guard !isClosed else { return }
            self.controller = controller
            controller.fileSystem = try await SessionFileSystem(controller: controller)
            guard !isClosed else { await controller.close(); return }
            let command = AgentCommand(
                executable: agent.executable,
                arguments: agent.arguments,
                environment: resolution.values,
                currentDirectory: URL(filePath: controller.session.workingDirectory)
            )
            let process = try await Task.detached { try AgentProcess(launching: command) }.value
            self.process = process
            guard !isClosed else { await cleanup(); return }
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
                options: .init(elicitation: true)
            )
            guard !isClosed else { await connection.close(); await cleanup(); return }
            let client = ACP.Implementation(name: "Agenthesia", version: "0.1")
            if case .saved = launch {
                try await controller.reopen(connection: connection, client: client)
            } else {
                try await controller.start(connection: connection, client: client)
            }
            guard !isClosed else { await cleanup(); return }
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
        } catch {
            if !isClosed {
                errorMessage =
                    error as? SessionController.SessionError == .cannotReopen
                    ? "\(agentName) cannot continue saved sessions."
                    : controller?.errorMessage ?? error.localizedDescription
            }
            await controller?.close()
            await cleanup()
        }
    }

    private func create(
        directory: URL,
        agent: AgentInstallRecord,
        worktreesRoot: URL?,
        additionalDirectories: [URL],
        store: PersistenceStore
    ) async throws -> SessionController {
        let id = UUID()
        _ = await library.claim(id)
        claimed = id
        let workspace: SessionWorkspace
        if let worktreesRoot {
            workspace = try await SessionWorkspace.prepare(directory: directory, id: id, worktreesRoot: worktreesRoot)
        } else {
            workspace = try await SessionWorkspace.prepare(directory: directory, id: id)
        }
        workingDirectory = workspace.workingDirectory
        guard !isClosed else { throw CancellationError() }
        let project = try await library.project(directory: workspace.projectDirectory)
        let install = try await library.install(agent)
        guard !isClosed else { throw CancellationError() }
        return SessionController(
            session: SessionRecord(
                id: id,
                projectID: project.id,
                agentInstallID: install.id,
                title: "\(install.name) · \(project.name)",
                workingDirectory: workspace.workingDirectory.path,
                baseRevision: workspace.baseRevision
            ),
            store: store,
            additionalDirectories: additionalDirectories.map { $0.path(percentEncoded: false) }
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
        let task = Task {
            await controller?.close()
            await cleanup()
            await startup?.value
            // Startup may have been awaiting Process.run when close began.
            await controller?.close()
            await cleanup()
            await exitTask?.value
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

    private func cleanup() async {
        if let claimed {
            self.claimed = nil
            await library.release(claimed)
        }
        guard let process else { return }
        _ = await process.terminate()
        await process.waitForStderr()
        stderrLog = await process.stderrLog
        logTask?.cancel()
        logTask = nil
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
