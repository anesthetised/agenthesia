import Darwin
import Foundation

/// Bounded process capture. Failures discard output; exit status is the raw waitpid status.
enum CommandOutput: Equatable, Sendable {
    case success(Data, Int32)
    case timedOut
    case tooMuchOutput
    case launchFailed

    static func capture(
        _ command: AgentCommand,
        timeout: Duration = .seconds(5),
        limit: Int = 65_536,
        complete: @escaping @Sendable (Data) -> Bool = { _ in false }
    ) async -> CommandOutput {
        let values =
            [command.executable] + command.arguments
            + (command.environment ?? [:]).flatMap { [$0.key, $0.value] }
            + [command.currentDirectory?.path(percentEncoded: false) ?? ""]
        guard command.executable.hasPrefix("/"), !values.contains(where: { $0.contains("\0") }),
            !(command.environment ?? [:]).keys.contains(where: { $0.isEmpty || $0.contains("=") })
        else { return .launchFailed }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: CommandOutputCollector.run(
                        command: command,
                        complete: complete,
                        timeout: timeout,
                        limit: max(1, limit)
                    )
                )
            }
        }
    }
}

/// The blocking capture stays off Swift's cooperative executor.
private enum CommandOutputCollector {
    static func run(
        command: AgentCommand,
        complete: @Sendable (Data) -> Bool,
        timeout: Duration,
        limit: Int
    ) -> CommandOutput {
        var stdout = [Int32](repeating: -1, count: 2)
        var stderr = [Int32](repeating: -1, count: 2)
        guard pipe(&stdout) == 0 else { return .launchFailed }
        defer { for fd in stdout where fd >= 0 { Darwin.close(fd) } }
        guard pipe(&stderr) == 0 else { return .launchFailed }
        defer { for fd in stderr where fd >= 0 { Darwin.close(fd) } }
        guard moveAboveStdio(&stdout[0]), moveAboveStdio(&stdout[1]),
            moveAboveStdio(&stderr[0]), moveAboveStdio(&stderr[1])
        else { return .launchFailed }
        guard makeNonblocking(stdout[0]), makeNonblocking(stderr[0]) else { return .launchFailed }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, stdout[0]) == 0,
            posix_spawn_file_actions_addclose(&actions, stderr[0]) == 0,
            posix_spawn_file_actions_addclose(&actions, stdout[1]) == 0,
            posix_spawn_file_actions_addclose(&actions, stderr[1]) == 0
        else { return .launchFailed }

        if let directory = command.currentDirectory {
            guard posix_spawn_file_actions_addchdir_np(&actions, directory.path(percentEncoded: false)) == 0 else {
                return .launchFailed
            }
        }
        guard
            let pid = try? spawnInNewSession(
                path: command.executable,
                arguments: [command.executable] + command.arguments,
                environment: command.environment ?? ProcessInfo.processInfo.environment,
                actions: &actions
            )
        else { return .launchFailed }
        Darwin.close(stdout[1])
        Darwin.close(stderr[1])
        stdout[1] = -1
        stderr[1] = -1

        let outcome = capture(
            pid: pid,
            stdout: stdout[0],
            stderr: stderr[0],
            complete: complete,
            timeout: timeout,
            limit: limit
        )
        return outcome
    }

    private static func capture(
        pid: pid_t,
        stdout: Int32,
        stderr: Int32,
        complete: @Sendable (Data) -> Bool,
        timeout: Duration,
        limit: Int
    ) -> CommandOutput {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var bytes = Data()
        var status: Int32 = 0
        var reaped = false
        var stdoutEnded = false
        var stderrEnded = false
        var outcome: CommandOutput = .timedOut
        while true {
            reap(pid, status: &status, reaped: &reaped)
            if reaped {
                if complete(bytes) || stdoutEnded {
                    outcome = .success(bytes, status)
                    break
                }
            }
            if clock.now >= deadline { break }
            var descriptors = [
                pollfd(fd: stdoutEnded ? -1 : stdout, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrEnded ? -1 : stderr, events: Int16(POLLIN), revents: 0),
            ]
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 20) }
            if ready < 0 && errno != EINTR { break }
            if descriptors[0].revents != 0 {
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(stdout, &chunk, chunk.count)
                if count == 0 {
                    stdoutEnded = true
                } else if count > 0 {
                    if count > limit - bytes.count {
                        outcome = .tooMuchOutput
                        break
                    }
                    bytes.append(contentsOf: chunk.prefix(count))
                } else if errno != EAGAIN && errno != EINTR {
                    stdoutEnded = true
                }
            }
            if descriptors[1].revents != 0 {
                var discarded = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(stderr, &discarded, discarded.count)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { stderrEnded = true }
            }
        }
        cleanUpGroup(pid, status: &status, reaped: &reaped)
        return outcome
    }

    private static func reap(_ pid: pid_t, status: inout Int32, reaped: inout Bool) {
        guard !reaped else { return }
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == pid { reaped = true }
        if result < 0 && errno == ECHILD {
            status = -1
            reaped = true
        }
    }

    private static func cleanUpGroup(_ pid: pid_t, status: inout Int32, reaped: inout Bool) {
        // POSIX_SPAWN_SETSID makes pid the session and process-group leader.
        if kill(-pid, 0) == 0 || errno == EPERM { kill(-pid, SIGTERM) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while ContinuousClock.now < deadline {
            reap(pid, status: &status, reaped: &reaped)
            if kill(-pid, 0) != 0 && errno == ESRCH { break }
            usleep(10_000)
        }
        if kill(-pid, 0) == 0 || errno == EPERM { kill(-pid, SIGKILL) }
        let reapDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while !reaped && ContinuousClock.now < reapDeadline {
            reap(pid, status: &status, reaped: &reaped)
            if !reaped { usleep(10_000) }
        }
        if !reaped {
            // Keep the capture deadline bounded; the utility queue owns the final reap.
            DispatchQueue.global(qos: .utility).async {
                var finalStatus: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(pid, &finalStatus, 0) } while result < 0 && errno == EINTR
            }
        }
    }

    private static func moveAboveStdio(_ fd: inout Int32) -> Bool {
        guard fd >= STDERR_FILENO + 1 else {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard moved >= 0 else { return false }
            Darwin.close(fd)
            fd = moved
            return true
        }
        return true
    }

    private static func makeNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }
}
