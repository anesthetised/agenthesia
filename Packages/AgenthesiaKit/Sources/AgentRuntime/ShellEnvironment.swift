import Darwin
public import Foundation
import Synchronization

/// Resolves the user's interactive login-shell environment once for agent launches.
public actor ShellEnvironment {
    public struct Resolution: Sendable {
        public let environment: [String: String]
        /// A safe, value-free explanation when the inherited environment was used instead.
        public let diagnostic: String?
    }

    public static let shared = ShellEnvironment()

    private let shell: String?
    private let inherited: [String: String]
    private let timeout: Duration
    private let outputLimit: Int
    private var resolution: Resolution?
    private var inFlight: Task<Resolution, Never>?

    public init(
        shell: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        outputLimit: Int = 1_048_576
    ) {
        self.shell = shell
        self.inherited = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func resolve() async -> Resolution {
        if let resolution { return resolution }
        let task: Task<Resolution, Never>
        if let inFlight {
            task = inFlight
        } else {
            let shell = shell
            let inherited = inherited
            let timeout = timeout
            let outputLimit = outputLimit
            task = Task.detached {
                await Self.capture(shell: shell, inherited: inherited, timeout: timeout, outputLimit: outputLimit)
            }
            inFlight = task
        }
        let result = await task.value
        resolution = result
        inFlight = nil
        return result
    }

    private nonisolated static func capture(
        shell explicitShell: String?,
        inherited: [String: String],
        timeout: Duration,
        outputLimit: Int
    ) async -> Resolution {
        let account = accountDetails()
        let userShell = account?.shell
        let userHome = account?.home
        let userName = account?.user
        let candidates = explicitShell.map { [$0] } ?? [inherited["SHELL"], userShell, "/bin/zsh"].compactMap { $0 }
        guard let shell = candidates.first(where: validShell) else {
            return Resolution(
                environment: fallback(inherited, shell: userShell ?? "/bin/zsh", home: userHome, user: userName),
                diagnostic: "Login shell is unavailable; using the inherited environment."
            )
        }

        let marker = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__AGENTHESIA_ENV_START_\(marker)__"
        let end = "__AGENTHESIA_ENV_END_\(marker)__"
        let script = "printf '\\n\(start)\\n'; /usr/bin/env -0; printf '\\n\(end)\\n'"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.environment = essentials(inherited, shell: shell, home: userHome, user: userName)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let collector = ShellOutputCollector(
            process: process,
            stdout: stdout,
            stderr: stderr,
            limit: max(1, outputLimit)
        )
        let outcome = await collector.run(timeout: timeout)
        if case .success(let bytes, let status) = outcome, status == 0,
            let environment = parse(bytes, start: start, end: end)
        {
            return Resolution(
                environment: essentials(environment, shell: shell, home: userHome, user: userName),
                diagnostic: nil
            )
        }
        let reason: String
        switch outcome {
        case .timedOut: reason = "Login shell timed out"
        case .tooMuchOutput: reason = "Login shell output exceeded the limit"
        case .launchFailed: reason = "Login shell could not start"
        case .success: reason = "Login shell did not return a valid environment"
        }
        return Resolution(
            environment: fallback(inherited, shell: shell, home: userHome, user: userName),
            diagnostic: "\(reason); using the inherited environment."
        )
    }

    private nonisolated static func validShell(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }

    private nonisolated static func accountDetails() -> (shell: String, home: String, user: String)? {
        var record = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            let status = getpwuid_r(getuid(), &record, bytes.baseAddress, bytes.count, &found)
            guard status == 0, found != nil else { return nil }
            return (String(cString: record.pw_shell), String(cString: record.pw_dir), String(cString: record.pw_name))
        }
    }

    private nonisolated static func essentials(
        _ environment: [String: String],
        shell: String,
        home: String?,
        user: String?
    ) -> [String: String] {
        var result = environment
        if result["HOME"] == nil { result["HOME"] = home ?? NSHomeDirectory() }
        if result["USER"] == nil, let user { result["USER"] = user }
        if result["SHELL"] == nil { result["SHELL"] = shell }
        return result
    }

    private nonisolated static func fallback(
        _ environment: [String: String],
        shell: String,
        home: String?,
        user: String?
    ) -> [String: String] {
        var result = essentials(environment, shell: shell, home: home, user: user)
        let paths = (result["PATH"] ?? "").split(separator: ":").map(String.init)
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        result["PATH"] = (paths + defaults.filter { !paths.contains($0) }).joined(separator: ":")
        return result
    }

    private nonisolated static func parse(_ data: Data, start: String, end: String) -> [String: String]? {
        let startBytes = Data("\n\(start)\n".utf8)
        let endBytes = Data("\n\(end)\n".utf8)
        guard let startRange = data.range(of: startBytes),
            let endRange = data.range(of: endBytes, in: startRange.upperBound..<data.endIndex),
            endRange.lowerBound > startRange.upperBound
        else { return nil }
        let payload = data[startRange.upperBound..<endRange.lowerBound]
        guard payload.last == 0 else { return nil }
        var result: [String: String] = [:]
        for entry in payload.split(separator: 0, omittingEmptySubsequences: true) {
            guard let equal = entry.firstIndex(of: 61), equal != entry.startIndex,
                let key = String(data: entry[..<equal], encoding: .utf8),
                let value = String(data: entry[entry.index(after: equal)...], encoding: .utf8)
            else { return nil }
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }
}

private enum ShellOutput: Sendable {
    case success(Data, Int32)
    case timedOut
    case tooMuchOutput
    case launchFailed
}

/// Mutable callback state is protected by the mutex.
private final class ShellOutputCollector: Sendable {
    private struct State: Sendable {
        var bytes = Data()
        var exited: Int32?
        var stdoutEnded = false
        var finished = false
        var group = false
        var deadline: Task<Void, Never>?
        var continuation: CheckedContinuation<ShellOutput, Never>?
    }

    private let state = Mutex(State())
    private let process: Process
    private let stdout: Pipe
    private let stderr: Pipe
    private let stdoutFD: Mutex<Int32?>
    private let stderrFD: Mutex<Int32?>
    private let limit: Int

    init(process: Process, stdout: Pipe, stderr: Pipe, limit: Int) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        stdoutFD = Mutex(stdout.fileHandleForReading.fileDescriptor)
        stderrFD = Mutex(stderr.fileHandleForReading.fileDescriptor)
        self.limit = limit
    }

    func run(timeout: Duration) async -> ShellOutput {
        await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
            Self.makeNonblocking(stdout.fileHandleForReading.fileDescriptor)
            Self.makeNonblocking(stderr.fileHandleForReading.fileDescriptor)
            process.terminationHandler = { [weak self] finished in
                self?.completeExit(finished.terminationStatus)
            }
            do {
                try process.run()
                stdout.fileHandleForWriting.closeFile()
                stderr.fileHandleForWriting.closeFile()
                let pid = process.processIdentifier
                // Foundation may create a separate group. Never signal an inherited group.
                let group = pid != getpgrp() && (getpgid(pid) == pid || kill(-pid, 0) == 0)
                state.withLock { $0.group = group }
                // The child may already have exited; pipes retain its output until handlers start.
                stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self, let chunk = read(from: stderrFD) else { return }
                    if chunk.isEmpty { handle.readabilityHandler = nil }
                }
                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self, let chunk = read(from: stdoutFD) else { return }
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        completeStdout()
                    } else {
                        append(chunk)
                    }
                }
                let deadline = Task.detached { [self] in
                    do {
                        try await Task.sleep(for: timeout)
                        _ = finish(.timedOut)
                    } catch {}
                }
                state.withLock { state in
                    if state.finished { deadline.cancel() } else { state.deadline = deadline }
                }
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                _ = finish(.launchFailed)
            }
        }
    }

    private func append(_ chunk: Data) {
        let overflow = state.withLock { state in
            guard !state.finished else { return false }
            if chunk.count > limit - state.bytes.count { return true }
            state.bytes.append(chunk)
            return false
        }
        if overflow { _ = finish(.tooMuchOutput) }
    }

    private func completeStdout() {
        let result = state.withLock { state -> ShellOutput? in
            state.stdoutEnded = true
            if let status = state.exited, !state.finished { return .success(state.bytes, status) }
            return nil
        }
        if let result { _ = finish(result) }
    }

    private func completeExit(_ status: Int32) {
        let result = state.withLock { state -> ShellOutput? in
            state.exited = status
            if state.stdoutEnded && !state.finished { return .success(state.bytes, status) }
            return nil
        }
        if let result { _ = finish(result) }
    }

    @discardableResult
    private func finish(_ result: ShellOutput) -> Bool {
        let completed = state.withLock {
            state -> (CheckedContinuation<ShellOutput, Never>, Bool, Task<Void, Never>?)? in
            guard !state.finished else { return nil }
            state.finished = true
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            let deadline = state.deadline
            state.deadline = nil
            return (continuation, state.group, deadline)
        }
        guard let (continuation, group, deadline) = completed else { return false }
        deadline?.cancel()
        let cleanupScheduled: Bool
        if case .success = result {
            if group, kill(-process.processIdentifier, 0) == 0 {
                Self.signal(process: process, group: true, continuation: continuation, result: result)
                cleanupScheduled = true
            } else {
                cleanupScheduled = false
            }
        } else if process.processIdentifier > 0 {
            let group = group || (process.isRunning && getpgid(process.processIdentifier) == process.processIdentifier)
            Self.signal(process: process, group: group, continuation: continuation, result: result)
            cleanupScheduled = true
        } else {
            cleanupScheduled = false
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        close(stdout.fileHandleForReading, descriptor: stdoutFD)
        close(stderr.fileHandleForReading, descriptor: stderrFD)
        if !cleanupScheduled { continuation.resume(returning: result) }
        return true
    }

    private static func signal(
        process: Process,
        group: Bool,
        continuation: CheckedContinuation<ShellOutput, Never>,
        result: ShellOutput
    ) {
        let pid = process.processIdentifier
        if group {
            kill(-pid, SIGTERM)
        } else if process.isRunning {
            kill(pid, SIGTERM)
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            if group {
                // The original group may outlive its leader because startup scripts fork.
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            } else if process.isRunning {
                kill(pid, SIGKILL)
            }
            for _ in 0..<5 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
            continuation.resume(returning: result)
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func read(from descriptor: borrowing Mutex<Int32?>) -> Data? {
        descriptor.withLock { descriptor in
            guard let fd = descriptor else { return nil }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 { return nil }
            return Data(bytes.prefix(count))
        }
    }

    private func close(_ handle: FileHandle, descriptor: borrowing Mutex<Int32?>) {
        descriptor.withLock { descriptor in
            guard descriptor != nil else { return }
            descriptor = nil
            try? handle.close()
        }
    }
}
