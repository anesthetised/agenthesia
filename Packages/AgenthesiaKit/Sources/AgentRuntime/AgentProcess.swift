import Darwin
public import Foundation
public import JSONRPC
import Synchronization

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

public struct AgentCommand: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    /// The full environment; nil inherits this process's environment.
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

/// A running agent process: JSON-RPC over stdin and stdout, logs on stderr.
public actor AgentProcess {
    public nonisolated let transport: FileHandleTransport
    /// Live lines; a slow consumer retains at most 64 lines.
    public nonisolated let stderr: AsyncStream<String>
    public nonisolated let processIdentifier: Int32

    private let process: Process
    private let processGroup: Int32?
    private let stderrCapture: StderrCapture
    private var exitStatus: ExitStatus?
    private var exitWaiters: [CheckedContinuation<ExitStatus, Never>] = []
    private var groupCleanupDeadline: ContinuousClock.Instant?
    private var groupCleanupTask: Task<Void, Never>?
    private var terminationTask: Task<ExitStatus, Never>?

    public init(launching command: AgentCommand) throws {
        let process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(filePath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
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

        let exit = Mutex<(@Sendable (ExitStatus) -> Void)?>(nil)
        process.terminationHandler = { process in
            let status: ExitStatus =
                process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
            exit.withLock { $0 }?(status)
        }

        do {
            try process.run()
        } catch {
            for handle in [
                stdin.fileHandleForReading, stdin.fileHandleForWriting,
                stdout.fileHandleForReading, stdout.fileHandleForWriting,
                stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
            ] {
                try? handle.close()
            }
            throw error
        }

        let pid = process.processIdentifier
        let observedGroup = getpgid(pid)
        if observedGroup > 0 && observedGroup != pid && process.isRunning {
            // A private group is required. Do not expose an agent we cannot safely clean up.
            kill(pid, SIGKILL)
            process.waitUntilExit()
            for handle in [
                stdin.fileHandleForReading, stdin.fileHandleForWriting,
                stdout.fileHandleForReading, stdout.fileHandleForWriting,
                stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
            ] {
                try? handle.close()
            }
            throw POSIXError(.EPERM)
        }
        self.process = process
        processIdentifier = pid
        // A child can exit before getpgid; its descendants can still hold its group.
        processGroup = pid != getpgrp() && (observedGroup == pid || kill(-pid, 0) == 0) ? pid : nil
        let capture = StderrCapture(handle: stderrPipe.fileHandleForReading)
        stderrCapture = capture
        stderr = capture.lines
        transport = FileHandleTransport(reading: stdout.fileHandleForReading, writing: stdin.fileHandleForWriting)
        exit.withLock { handler in
            handler = { [weak self] status in
                Task { await self?.didExit(status) }
            }
        }
        if !process.isRunning {
            let status: ExitStatus =
                process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
            Task { await self.didExit(status) }
        }
    }

    public var isRunning: Bool { exitStatus == nil }
    /// Last 64 KiB of stderr. For a finalized snapshot, call waitForStderr first.
    public var stderrLog: String { stderrCapture.snapshot }

    public func waitForExit() async -> ExitStatus {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Waits for the leader to exit, then waits up to 500 ms for stderr EOF.
    /// A descendant retaining the pipe cannot keep this suspended indefinitely.
    public func waitForStderr() async {
        _ = await waitForExit()
        await stderrCapture.waitForDrain()
    }

    /// Idempotent SIGTERM/SIGKILL group cleanup. Later calls can shorten, but never
    /// extend, the grace period. Caller cancellation does not stop cleanup.
    @discardableResult
    public func terminate(gracePeriod: Duration = .seconds(3)) async -> ExitStatus {
        let cleanup = ensureGroupCleanup(gracePeriod: gracePeriod)
        if let terminationTask { return await terminationTask.value }
        let task = Task { await performTermination(cleanup: cleanup) }
        terminationTask = task
        return await task.value
    }

    private func performTermination(cleanup: Task<Void, Never>) async -> ExitStatus {
        await transport.close()
        await cleanup.value
        let status = await waitForExit()
        await waitForStderr()
        return status
    }

    private func ensureGroupCleanup(gracePeriod: Duration) -> Task<Void, Never> {
        let requestedDeadline = ContinuousClock.now.advanced(by: gracePeriod)
        if let groupCleanupDeadline {
            self.groupCleanupDeadline = min(groupCleanupDeadline, requestedDeadline)
        } else {
            groupCleanupDeadline = requestedDeadline
        }
        if let groupCleanupTask { return groupCleanupTask }
        let task = Task { await performGroupCleanup() }
        groupCleanupTask = task
        return task
    }

    private func performGroupCleanup() async {
        if let processGroup {
            if groupExists(processGroup) { kill(-processGroup, SIGTERM) }
            while groupExists(processGroup) && ContinuousClock.now < (groupCleanupDeadline ?? .now) {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            if groupExists(processGroup) { kill(-processGroup, SIGKILL) }
        } else if process.isRunning {
            // The child has no verified private group; signal only its live leader.
            kill(processIdentifier, SIGTERM)
            while process.isRunning && ContinuousClock.now < (groupCleanupDeadline ?? .now) {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            if process.isRunning { kill(processIdentifier, SIGKILL) }
        }
    }

    private func groupExists(_ group: Int32) -> Bool {
        guard group > 0, group != getpgrp() else { return false }
        return kill(-group, 0) == 0 || errno == EPERM
    }

    private func didExit(_ status: ExitStatus) {
        guard exitStatus == nil else { return }
        exitStatus = status
        for waiter in exitWaiters { waiter.resume(returning: status) }
        exitWaiters.removeAll()
        if processGroup != nil {
            _ = ensureGroupCleanup(gracePeriod: .seconds(3))
        }
    }
}

/// Bounded stderr framing, retention and EOF notification for the pipe callback.
private final class StderrCapture: Sendable {
    private static let byteLimit = 64 * 1024
    private static let lineLimit = 16 * 1024
    private static let omitted = "[earlier stderr omitted]\n"

    private struct State {
        var pending = Data()
        var log = Data()
        var pendingTruncated = false
        var logTruncated = false
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let handle: FileHandle
    private let descriptor: Int32
    private let state = Mutex(State())
    private let readOpen = Mutex(true)

    init(handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        (lines, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        handle.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            let chunk = readOpen.withLock { open -> Data? in
                guard open else { return nil }
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { return Data(bytes.prefix(count)) }
                if count == 0 || (errno != EINTR && errno != EAGAIN) { return Data() }
                return nil
            }
            guard let chunk else { return }
            if chunk.isEmpty { finish() } else { append(chunk) }
        }
    }

    var snapshot: String {
        state.withLock { state in
            (state.logTruncated ? Self.omitted : "")
                + String(decoding: state.log, as: UTF8.self)
        }
    }

    func waitForDrain() async {
        let timeout = Task { [self] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { finish() }
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            state.withLock { state in
                if state.finished { waiter.resume() } else { state.waiters.append(waiter) }
            }
        }
        timeout.cancel()
    }

    private func append(_ chunk: Data) {
        state.withLock { state in
            guard !state.finished else { return }
            state.log.append(chunk)
            let retainedLimit = Self.byteLimit - Self.omitted.utf8.count
            if state.log.count > retainedLimit {
                state.logTruncated = true
                state.log = Data(state.log.suffix(retainedLimit))
                // A byte cap can cut into a UTF-8 scalar; discard that partial prefix.
                while let first = state.log.first, first & 0xC0 == 0x80 {
                    state.log.removeFirst()
                }
            }
            let segments = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, segment) in segments.enumerated() {
                state.pending.append(contentsOf: segment)
                if state.pending.count > Self.lineLimit {
                    state.pending = Data(state.pending.suffix(Self.lineLimit))
                    while let first = state.pending.first, first & 0xC0 == 0x80 {
                        state.pending.removeFirst()
                    }
                    state.pendingTruncated = true
                }
                if index < segments.count - 1 { emitPending(&state) }
            }
        }
    }

    private func emitPending(_ state: inout State) {
        if state.pending.last == 0x0D { state.pending.removeLast() }
        guard !state.pending.isEmpty else { return }
        let line =
            (state.pendingTruncated ? "[line truncated] " : "")
            + String(decoding: state.pending, as: UTF8.self)
        continuation.yield(line)
        state.pending.removeAll(keepingCapacity: true)
        state.pendingTruncated = false
    }

    private func finish() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.finished else { return [] }
            state.finished = true
            emitPending(&state)
            continuation.finish()
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        handle.readabilityHandler = nil
        readOpen.withLock { open in
            if open {
                open = false
                try? handle.close()
            }
        }
        for waiter in waiters { waiter.resume() }
    }
}
