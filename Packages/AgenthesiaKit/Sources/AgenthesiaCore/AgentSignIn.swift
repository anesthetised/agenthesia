public import ACP
import AgentRuntime
public import Foundation
import JSONRPC
import Observation

/// One sign-in from Settings, with no project or session (ADR-0038).
@MainActor @Observable
public final class AgentSignIn: Identifiable {
    public enum State: Equatable, Sendable {
        case idle, initializing, ready
        case signingIn(ACP.AuthMethodID)
        case completed
        case failed(String)
        case closing, closed
    }

    public let id = UUID()
    public let name: String
    public private(set) var state = State.idle
    public private(set) var methods: [ACP.AuthMethod] = []
    public private(set) var terminal: SignInTerminal?

    @ObservationIgnored private let prepareCommand:
        @Sendable (URL) async throws -> (AgentCommand, AgentInstaller.Lease?)
    @ObservationIgnored private let launch: @Sendable (AgentCommand) async throws -> AgentProcess
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var command: AgentCommand?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var lease: AgentInstaller.Lease?
    @ObservationIgnored private var process: AgentProcess?
    @ObservationIgnored private var connection: ACP.V1.AgentConnectionAdapter?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?

    init(
        name: String,
        timeout: Duration = .seconds(20),
        launch: @escaping @Sendable (AgentCommand) async throws -> AgentProcess = { command in
            try await Task.detached { try AgentProcess(launching: command) }.value
        },
        prepare: @escaping @Sendable (URL) async throws -> (AgentCommand, AgentInstaller.Lease?)
    ) {
        self.name = name
        self.timeout = timeout
        self.launch = launch
        prepareCommand = prepare
    }

    /// Starts the configured agent and obtains a fresh method list. A retry does not reuse old methods.
    public func prepare() async {
        guard operation == nil, closing == nil else { return }
        switch state {
        case .idle, .failed: break
        default: return
        }
        state = .initializing
        methods = []
        terminal = nil
        await perform {
            let directory = FileManager.default.temporaryDirectory.appending(path: "agenthesia-sign-in-\(UUID())")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            self.directory = directory
            let (command, lease) = try await self.prepareCommand(directory)
            self.lease = lease
            self.command = command
            self.command?.currentDirectory = directory
            try Task.checkCancellation()
            try await self.connect()
            self.state = .ready
        }
    }

    public func signIn(with id: ACP.AuthMethodID) async {
        guard state == .ready, operation == nil, closing == nil,
            let method = methods.first(where: { $0.id == id })
        else { return }
        if case .unknown = method { return }
        state = .signingIn(id)
        await perform {
            switch method {
            case .agent:
                guard let connection = self.connection else { throw ConnectionError.closed }
                try await connection.authenticate(methodId: id)
            case .terminal(let method):
                try await self.signIn(on: method)
            case .unknown: return
            }
            try Task.checkCancellation()
            await self.cleanup()
            try Task.checkCancellation()
            self.terminal = nil
            self.state = .completed
        }
    }

    /// Stops and joins even an operation still acquiring a lease or launching a process.
    public func close() async {
        if let closing { await closing.value; return }
        state = .closing
        operation?.cancel()
        let task = Task {
            await self.stopProcesses()
            await self.operation?.value
            await self.cleanup()
            self.terminal = nil
            self.state = .closed
        }
        closing = task
        await task.value
    }

    /// Hides the output of a failed terminal method; Retry obtains a new method list.
    public func dismissTerminal() {
        guard case .failed = state else { return }
        terminal = nil
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async {
        let task = Task {
            do {
                try Task.checkCancellation()
                try await body()
            } catch {
                await self.cleanup()
                if self.closing == nil {
                    self.state = .failed(Self.message(for: error))
                }
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.close() }
        }
        operation = nil
    }

    private func connect() async throws {
        guard let command else { throw ConnectionError.closed }
        let process = try await launch(command)
        self.process = process
        try Task.checkCancellation()
        let connection = await ACP.V1.AgentConnectionAdapter(
            transport: process.transport,
            delegate: NoSession(),
            options: .init(terminalAuth: true, elicitation: false)
        )
        self.connection = connection
        try Task.checkCancellation()
        let timeout = timeout
        let profile = try await withThrowingTaskGroup(of: ACP.AgentProfile.self) { group in
            group.addTask { try await connection.initialize(client: .init(name: "Agenthesia", version: "0.1")) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentProbe.Failure.timedOut(seconds: Int(timeout.components.seconds))
            }
            defer { group.cancelAll() }
            do {
                guard let profile = try await group.next() else { throw CancellationError() }
                return profile
            } catch {
                await connection.close()
                throw error
            }
        }
        try Task.checkCancellation()
        methods = profile.authMethods
        Task { [weak self] in
            let status = await process.waitForExit()
            guard let self else { return }
            // Preparation or a method may already be handling the exit. Do not race its result/cleanup.
            await self.operation?.value
            guard self.process === process, self.state == .ready else { return }
            await self.perform { throw Failure(message: "The agent \(status). Try signing in again.") }
        }
    }

    private func signIn(on method: ACP.TerminalAuthMethod) async throws {
        await stopProcesses()
        try Task.checkCancellation()
        guard var command else { throw ConnectionError.closed }
        command.arguments += method.args ?? []
        command.environment = (command.environment ?? [:]).merging(method.env ?? [:]) { $1 }
        command.environment?["TERM"] = "xterm-256color"
        let process = try await Task.detached { try TerminalProcess(launching: command) }.value
        let terminal = SignInTerminal(title: method.name, process: process)
        self.terminal = terminal
        try Task.checkCancellation()
        let status = await terminal.waitForExit()
        try Task.checkCancellation()
        guard status == .exited(0) else { throw Failure(message: "Sign-in \(status).") }
        await terminal.terminate()
        self.terminal = nil
        try Task.checkCancellation()
        try await connect()
    }

    private func stopProcesses() async {
        await terminal?.terminate()
        if let connection {
            await connection.close()
            if self.connection === connection { self.connection = nil }
        }
        if let process {
            await process.terminate(gracePeriod: .seconds(1))
            if self.process === process { self.process = nil }
        }
    }

    private func cleanup() async {
        await stopProcesses()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            self.directory = nil
        }
        command = nil
        lease?.release()
        lease = nil
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as RPCError: error.message
        case is CancellationError: "Sign-in cancelled."
        case ConnectionError.closed: "The agent exited or closed its connection. Try signing in again."
        case ACP.V1.ClientError.unsupportedProtocolVersion(let version):
            AgentProbe.Failure.unsupportedProtocol(version).localizedDescription
        default: error.localizedDescription
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct NoSession: ACP.AgentConnectionDelegate {
        func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {}
        func requestPermission(
            for toolCall: ACP.ToolCallUpdate,
            options: [ACP.PermissionOption],
            in sessionId: ACP.SessionID
        ) async -> ACP.PermissionOutcome { .cancelled }
    }
}
