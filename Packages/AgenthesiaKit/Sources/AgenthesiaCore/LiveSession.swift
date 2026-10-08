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
        guard startup == nil, controller == nil, !isClosed else { return }
        isStarting = true
        let task = Task {
            await launch(
                directory: directory,
                agent: agent,
                worktreesRoot: worktreesRoot,
                additionalDirectories: additionalDirectories
            )
        }
        startup = task
        await task.value
    }

    private func launch(
        directory: URL,
        agent: AgentInstallRecord,
        worktreesRoot: URL?,
        additionalDirectories: [URL]
    ) async {
        defer { isStarting = false }
        do {
            let store = try await library.store()
            guard !isClosed else { return }
            // Resolve and check the command first, so a mistyped executable does not leave a worktree behind.
            let resolution = await environment()
            diagnostic = resolution.diagnostic
            guard !isClosed else { return }
            guard Self.isExecutable(agent.executable, path: resolution.values["PATH"]) else {
                throw LaunchError(message: "Cannot find an executable named “\(agent.executable)”.")
            }
            let id = UUID()
            let workspace: SessionWorkspace
            if let worktreesRoot {
                workspace = try await SessionWorkspace.prepare(
                    directory: directory,
                    id: id,
                    worktreesRoot: worktreesRoot
                )
            } else {
                workspace = try await SessionWorkspace.prepare(directory: directory, id: id)
            }
            workingDirectory = workspace.workingDirectory
            guard !isClosed else { return }
            let project = try await library.project(directory: workspace.projectDirectory)
            let install = try await library.install(agent)
            guard !isClosed else { return }
            let controller = SessionController(
                session: SessionRecord(
                    id: id,
                    projectID: project.id,
                    agentInstallID: install.id,
                    title: "\(install.name) · \(project.name)",
                    workingDirectory: workspace.workingDirectory.path
                ),
                store: store,
                additionalDirectories: additionalDirectories.map { $0.path(percentEncoded: false) }
            )
            self.controller = controller
            controller.fileSystem = try await SessionFileSystem(controller: controller)
            guard !isClosed else { await controller.close(); return }
            let command = AgentCommand(
                executable: install.executable,
                arguments: install.arguments,
                environment: resolution.values,
                currentDirectory: workspace.workingDirectory
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
                options: .init(elicitation: false)
            )
            guard !isClosed else { await connection.close(); await cleanup(); return }
            try await controller.start(connection: connection, client: .init(name: "Agenthesia", version: "0.1"))
            guard !isClosed else { await cleanup(); return }
            observeFailure()
            exitTask = Task { [weak self] in
                let status = await process.waitForExit()
                await process.waitForStderr()
                guard let self, !self.isClosed else { return }
                self.stderrLog = await process.stderrLog
                self.errorMessage =
                    self.controller?.errorMessage ?? "The agent \(status). Start a new session to continue."
                await self.controller?.close()
                await self.cleanup()
            }
        } catch {
            if !isClosed { errorMessage = controller?.errorMessage ?? error.localizedDescription }
            await controller?.close()
            await cleanup()
        }
    }

    public func send(_ text: String) async {
        guard let controller, !isClosed else { return }
        do { try await controller.send([.init(text: text)]) } catch {
            if !isClosed { errorMessage = controller.errorMessage ?? error.localizedDescription }
            if controller.status == .failed { await cleanup() }
        }
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
