import Darwin
public import Foundation

/// Resolves the user's interactive login-shell environment for agent launches, cached until explicitly refreshed.
public actor ShellEnvironment {
    public struct Resolution: Sendable {
        public let environment: [String: String]
        /// A safe, value-free explanation when the inherited environment was used instead.
        public let diagnostic: String?
    }

    public static let shared = ShellEnvironment()

    private let capture: @Sendable () async -> Resolution
    private var resolution: Resolution?
    private var inFlight: (id: UUID, refresh: Bool, task: Task<Resolution, Never>)?
    // Internal observation lets concurrency tests hold a capture until every waiter has joined.
    private(set) var waiterCount = 0

    public init(
        shell: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        outputLimit: Int = 1_048_576
    ) {
        capture = {
            await Self.capture(shell: shell, inherited: environment, timeout: timeout, outputLimit: outputLimit)
        }
    }

    init(capture: @escaping @Sendable () async -> Resolution) {
        self.capture = capture
    }

    public func resolve() async -> Resolution { await resolve(refresh: false) }

    /// Captures a new environment, sharing concurrent refreshes. Existing launch snapshots stay unchanged.
    public func refresh() async -> Resolution { await resolve(refresh: true) }

    private func resolve(refresh: Bool) async -> Resolution {
        if !refresh, let resolution { return resolution }
        let flight: (id: UUID, refresh: Bool, task: Task<Resolution, Never>)
        if let inFlight, !refresh || inFlight.refresh {
            flight = inFlight
        } else {
            resolution = nil
            let capture = capture
            flight = (UUID(), refresh, Task.detached { await capture() })
            inFlight = flight
        }
        waiterCount += 1
        defer { waiterCount -= 1 }
        let result = await flight.task.value
        if inFlight?.id == flight.id {
            resolution = result
            inFlight = nil
        }
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
        let outcome = await CommandOutput.capture(
            AgentCommand(executable: shell, arguments: ["-l", "-i", "-c", script], environment: launchEnvironment),
            timeout: timeout,
            limit: max(1, outputLimit),
            complete: { parse($0, start: start, end: end) != nil }
        )
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
