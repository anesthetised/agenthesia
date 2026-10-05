public import Foundation
public import JSONRPC
import Synchronization

/// How a child process ended.
public enum ExitStatus: Sendable, Hashable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var description: String {
        switch self {
        case .exited(let code): "exited with code \(code)"
        case .signaled(let signal): "killed by signal \(signal)"
        }
    }
}

/// A command to run as an agent.
public struct AgentCommand: Sendable, Hashable {
    /// An absolute path, or a name looked up in `PATH` of `environment`.
    public var executable: String
    public var arguments: [String]
    /// The full environment; `nil` inherits this process's environment.
    public var environment: [String: String]?
    public var currentDirectory: URL?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// A running agent process: JSON-RPC over its stdin and stdout, logs on its stderr.
public actor AgentProcess {
    /// The agent's stdin and stdout.
    public nonisolated let transport: FileHandleTransport
    /// The agent's stderr, line by line.
    public nonisolated let stderr: AsyncStream<String>
    public nonisolated let processIdentifier: Int32

    private let process: Process
    private var exitStatus: ExitStatus?
    private var exitWaiters: [CheckedContinuation<ExitStatus, Never>] = []

    /// Starts `command`. Throws if the executable cannot be launched.
    public init(launching command: AgentCommand) throws {
        let process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(filePath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        // Assigning nil would launch with an empty environment instead of inheriting this one.
        if let environment = command.environment {
            process.environment = environment
        }
        process.currentDirectoryURL = command.currentDirectory

        let stdin = Pipe()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrPipe

        let (stderr, stderrContinuation) = AsyncStream<String>.makeStream()
        let framer = Mutex(LineFramer())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let rest = framer.withLock({ $0.finish() }) {
                    stderrContinuation.yield(String(decoding: rest, as: UTF8.self))
                }
                stderrContinuation.finish()
            } else {
                for line in framer.withLock({ $0.append(chunk) }) {
                    stderrContinuation.yield(String(decoding: line, as: UTF8.self))
                }
            }
        }

        let exit = Mutex<(@Sendable (ExitStatus) -> Void)?>(nil)
        process.terminationHandler = { process in
            let status: ExitStatus =
                process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
            exit.withLock { $0 }?(status)
        }

        try process.run()
        self.process = process
        self.stderr = stderr
        processIdentifier = process.processIdentifier
        transport = FileHandleTransport(reading: stdout.fileHandleForReading, writing: stdin.fileHandleForWriting)
        exit.withLock { handler in
            handler = { [weak self] status in
                Task { await self?.didExit(status) }
            }
        }
        // The process may have exited before the handler was installed.
        if !process.isRunning {
            let status: ExitStatus =
                process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
            Task { await self.didExit(status) }
        }
    }

    public var isRunning: Bool { exitStatus == nil }

    /// Waits for the process to exit.
    public func waitForExit() async -> ExitStatus {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Asks the process to stop with SIGTERM, then kills it with SIGKILL after `gracePeriod`.
    @discardableResult
    public func terminate(gracePeriod: Duration = .seconds(3)) async -> ExitStatus {
        if let exitStatus { return exitStatus }
        await transport.close()
        kill(processIdentifier, SIGTERM)
        let pid = processIdentifier
        let escalation = Task {
            try await Task.sleep(for: gracePeriod)
            kill(pid, SIGKILL)
        }
        let status = await waitForExit()
        escalation.cancel()
        return status
    }

    private func didExit(_ status: ExitStatus) {
        guard exitStatus == nil else { return }
        exitStatus = status
        for waiter in exitWaiters {
            waiter.resume(returning: status)
        }
        exitWaiters.removeAll()
    }
}
