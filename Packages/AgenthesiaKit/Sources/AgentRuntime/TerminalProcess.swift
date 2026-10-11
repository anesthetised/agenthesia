import Darwin
public import Foundation
import Synchronization

/// Output retained by a ``TerminalProcess``: the raw bytes written to the pseudo-terminal.
public struct TerminalOutput: Sendable, Hashable {
    public var bytes: Data
    /// Whether earlier bytes were dropped to stay within the output limit.
    public var truncated: Bool

    public init(bytes: Data = Data(), truncated: Bool = false) {
        self.bytes = bytes
        self.truncated = truncated
    }
}

/// A command run for an agent in a pseudo-terminal (ADR-0015).
///
/// The command is executed directly, without a shell, as the leader of a new session and process group
/// with the pseudo-terminal as its controlling terminal. Nothing is written to its input. Output is read
/// continuously, since a terminal's last close waits until its output has been read, and the newest
/// bytes are retained up to the output limit.
public actor TerminalProcess {
    public static let defaultOutputLimit = 1_048_576
    static let columns: UInt16 = 80
    static let rows: UInt16 = 24

    public nonisolated let processIdentifier: Int32

    private let reader: TerminalReader
    private let groupTermination: ProcessGroupTermination
    private var exitStatus: ExitStatus?
    private var completion: ExitStatus?
    private var exitWaiters: [CheckedContinuation<ExitStatus, Never>] = []

    /// Resolves a bare `executable` through the command environment's `PATH`, and a relative one against
    /// its working directory. Throws `ENOENT` when no executable is found.
    public init(launching command: AgentCommand, outputLimit: Int = defaultOutputLimit) throws {
        let directory =
            command.currentDirectory?.path(percentEncoded: false) ?? FileManager.default.currentDirectoryPath
        let environment = command.environment ?? ProcessInfo.processInfo.environment
        guard let executable = Self.resolve(command.executable, path: environment["PATH"], in: directory) else {
            throw POSIXError(.ENOENT)
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var name = [CChar](repeating: 0, count: 128)
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(master, F_SETFL, O_NONBLOCK) == 0,
            grantpt(master) == 0,
            unlockpt(master) == 0,
            ptsname_r(master, &name, name.count) == 0
        else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(master)
            throw POSIXError(code)
        }
        // The window size can only be set through the terminal side; this descriptor is not the
        // command's controlling terminal and is closed once the command has its own.
        let terminal = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)
        defer { if terminal >= 0 { Darwin.close(terminal) } }

        let pid: pid_t
        do {
            var size = winsize(ws_row: Self.rows, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
            guard terminal >= 0, ioctl(terminal, TIOCSWINSZ, &size) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.ENOMEM) }
            defer { posix_spawn_file_actions_destroy(&actions) }
            // Opened after the new session is created, the terminal becomes its controlling terminal.
            guard posix_spawn_file_actions_addchdir(&actions, directory) == 0,
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, name, O_RDWR, 0) == 0,
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0
            else { throw POSIXError(.ENOMEM) }
            pid = try spawnInNewSession(
                path: executable,
                arguments: [command.executable] + command.arguments,
                environment: environment,
                actions: &actions
            )
        } catch {
            Darwin.close(master)
            throw error
        }

        processIdentifier = pid
        reader = TerminalReader(master: master, limit: max(1, outputLimit))
        // POSIX_SPAWN_SETSID makes the command the leader of its own process group.
        groupTermination = ProcessGroupTermination(group: pid, leader: pid) { false }

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            exit.cancel()
            let exitStatus = result == pid ? ExitStatus(waitStatus: status) : .exited(-1)
            Task { await self?.didExit(exitStatus) }
        }
        exit.resume()
    }

    public var isRunning: Bool { exitStatus == nil }

    /// The newest raw output, at most the output limit.
    public nonisolated var output: TerminalOutput { reader.output }

    /// Waits for the command to exit, then up to 500 ms for the end of its output. A descendant
    /// holding the terminal open cannot keep this suspended indefinitely.
    public func waitForExit() async -> ExitStatus {
        if let completion { return completion }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Idempotent SIGTERM/SIGKILL process-group cleanup. Later calls can shorten, but never extend, the
    /// grace period. Caller cancellation does not stop cleanup.
    @discardableResult
    public func terminate(gracePeriod: Duration = .seconds(3)) async -> ExitStatus {
        let cleanup = groupTermination.start(gracePeriod: gracePeriod)
        await cleanup.value
        return await waitForExit()
    }

    private func didExit(_ status: ExitStatus) async {
        guard exitStatus == nil else { return }
        exitStatus = status
        if !groupTermination.hasStarted {
            groupTermination.start(gracePeriod: .seconds(3))
        }
        await reader.waitForEnd(timeout: .milliseconds(500))
        completion = status
        for waiter in exitWaiters { waiter.resume(returning: status) }
        exitWaiters.removeAll()
    }

    static func resolve(_ command: String, path: String?, in directory: String) -> String? {
        guard !command.isEmpty else { return nil }
        func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : directory + "/" + path }
        if command.contains("/") { return absolute(command) }
        for entry in (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = absolute(entry.isEmpty ? "." : String(entry)) + "/" + command
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }
}

extension ExitStatus {
    init(waitStatus status: Int32) {
        self = status & 0x7F == 0 ? .exited((status >> 8) & 0xFF) : .signaled(status & 0x7F)
    }
}

/// Reads the pseudo-terminal's master side until end of file and retains the newest bytes.
private final class TerminalReader: Sendable {
    private struct State {
        var bytes = Data()
        var truncated = false
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let limit: Int
    private let source: any DispatchSourceRead
    private let state = Mutex(State())

    init(master: Int32, limit: Int) {
        self.limit = limit
        source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .utility))
        // The handlers keep the reader alive until the source is cancelled.
        source.setEventHandler { [self] in
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(master, &chunk, chunk.count)
            if count > 0 {
                append(chunk[..<count])
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [self] in
            Darwin.close(master)
            finish()
        }
        source.resume()
    }

    var output: TerminalOutput {
        state.withLock { state in
            TerminalOutput(
                bytes: Data(state.bytes.suffix(limit)),
                truncated: state.truncated || state.bytes.count > limit
            )
        }
    }

    /// Waits for end of file; after `timeout`, stops reading and closes the terminal.
    func waitForEnd(timeout: Duration) async {
        let timer = Task { [source] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { source.cancel() }
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            state.withLock { state in
                if state.finished { waiter.resume() } else { state.waiters.append(waiter) }
            }
        }
        timer.cancel()
    }

    private func append(_ chunk: ArraySlice<UInt8>) {
        state.withLock { state in
            state.bytes.append(contentsOf: chunk)
            // Dropping in batches keeps appends amortized O(1) for noisy commands.
            if state.bytes.count > limit + limit / 4 {
                state.bytes = Data(state.bytes.suffix(limit))
                state.truncated = true
            }
        }
    }

    private func finish() {
        let waiters = state.withLock { state in
            state.finished = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
