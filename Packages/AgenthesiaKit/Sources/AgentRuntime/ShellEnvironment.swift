import Darwin
public import Foundation

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
        let launchEnvironment = essentials(inherited, shell: shell, home: userHome, user: userName)
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: ShellOutputCollector.run(
                        shell: shell,
                        script: script,
                        environment: launchEnvironment,
                        start: start,
                        end: end,
                        timeout: timeout,
                        limit: max(1, outputLimit)
                    )
                )
            }
        }
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

    fileprivate nonisolated static func parse(_ data: Data, start: String, end: String) -> [String: String]? {
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

/// The blocking capture stays off Swift's cooperative executor.
private enum ShellOutputCollector {
    static func run(
        shell: String,
        script: String,
        environment: [String: String],
        start: String,
        end: String,
        timeout: Duration,
        limit: Int
    ) -> ShellOutput {
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

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        var defaultSignals = sigset_t()
        sigemptyset(&emptyMask)
        sigemptyset(&defaultSignals)
        for signal in [SIGTERM, SIGPIPE, SIGINT, SIGTTIN, SIGTTOU, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaultSignals, signal)
        }
        let flags = Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
        else { return .launchFailed }

        let arguments = [shell, "-l", "-i", "-c", script]
        let variables = environment.map { "\($0.key)=\($0.value)" }
        var argv = arguments.map { strdup($0) }
        var envp = variables.map { strdup($0) }
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return .launchFailed }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let spawnStatus = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { vars in
                shell.withCString { path in
                    posix_spawn(&pid, path, &actions, &attributes, args.baseAddress, vars.baseAddress)
                }
            }
        }
        guard spawnStatus == 0 else { return .launchFailed }
        Darwin.close(stdout[1])
        Darwin.close(stderr[1])
        stdout[1] = -1
        stderr[1] = -1

        let outcome = capture(
            pid: pid,
            stdout: stdout[0],
            stderr: stderr[0],
            start: start,
            end: end,
            timeout: timeout,
            limit: limit
        )
        return outcome
    }

    private static func capture(
        pid: pid_t,
        stdout: Int32,
        stderr: Int32,
        start: String,
        end: String,
        timeout: Duration,
        limit: Int
    ) -> ShellOutput {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var bytes = Data()
        var status: Int32 = 0
        var reaped = false
        var stdoutEnded = false
        var stderrEnded = false
        var outcome: ShellOutput = .timedOut
        while true {
            reap(pid, status: &status, reaped: &reaped)
            if reaped {
                if ShellEnvironment.parse(bytes, start: start, end: end) != nil || stdoutEnded {
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
