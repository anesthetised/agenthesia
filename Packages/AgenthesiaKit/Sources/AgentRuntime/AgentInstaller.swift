import CryptoKit
import Darwin
public import Foundation

/// Private versioned installations. UI/history integration belongs to the caller, not this store.
public actor AgentInstaller {
    public static let shared = AgentInstaller(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Agenthesia/Agents")
    )

    /// Retain for the entire authentication and session lifetime, until all owned processes have exited.
    /// Call `release` after those processes exit; copying `command` does not retain the lease.
    public final class Lease: Sendable {
        public let command: AgentCommand
        public let installation: AgentInstallation
        public let shellDiagnostic: String?
        private let lock: InstallationLock

        /// Idempotent. The command must not be launched again after releasing its lease.
        public func release() { lock.release() }

        fileprivate init(
            command: AgentCommand,
            installation: AgentInstallation,
            diagnostic: String?,
            lock: InstallationLock
        ) {
            self.command = command
            self.installation = installation
            shellDiagnostic = diagnostic
            self.lock = lock
        }
    }

    private let root: URL
    private let environment: ShellEnvironment
    private let runtime: NodeRuntime
    private let download: @Sendable (URL, URL) async throws -> Void
    private let run: @Sendable (AgentCommand) async -> CommandOutput
    private static let ownership = Data("Agenthesia agent installations v1\n".utf8)

    public init(root: URL, environment: ShellEnvironment = .shared) {
        self.init(root: root, environment: environment, download: { try await InstallationHTTP.download($0, to: $1) })
    }

    init(
        root: URL,
        environment: ShellEnvironment = .shared,
        runtime: NodeRuntime? = nil,
        download: @escaping @Sendable (URL, URL) async throws -> Void,
        run: @escaping @Sendable (AgentCommand) async -> CommandOutput = {
            await CommandOutput.capture($0, timeout: .seconds(300), limit: 1_048_576)
        }
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.environment = environment
        self.runtime = runtime ?? NodeRuntime(environment: environment)
        self.download = download
        self.run = run
    }

    /// Updates are explicit installations of another version; an existing version is never overwritten.
    public func install(_ agent: AgentRegistry.Agent) async throws -> AgentInstallation {
        try Task.checkCancellation()
        let target = try location(agentID: agent.id, version: agent.version)
        let id = UUID()
        let stage = root.appending(path: ".staging-\(id.uuidString)")
        try exclusively {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw AgentInstallation.Failure.alreadyInstalled
            }
            guard mkdir(stage.path(percentEncoded: false), 0o700) == 0 else {
                throw AgentInstallation.Failure.unownedPath
            }
        }
        do {
            try Data(id.uuidString.utf8).write(to: stage.appending(path: ".owner"), options: .withoutOverwriting)
        } catch {
            // Exclusive mkdir established ownership even if the first marker write failed.
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
        do {
            let payload = stage.appending(path: "payload")
            let source: AgentInstallation.Source
            let executable: String
            let arguments: [String]
            let variables: [String: String]
            switch agent.installation() {
            case .binary(let binary):
                let archive = stage.appending(path: "archive")
                try await download(binary.archive, archive)
                try Task.checkCancellation()
                if let checksum = binary.sha256 { try Self.verify(archive, checksum: checksum) }
                try await AgentArchive.extract(archive, to: payload)
                try FileManager.default.removeItem(at: archive)
                source = .binary(archive: binary.archive, sha256: binary.sha256)
                executable = try AgentArchive.relativePath(binary.command)
                arguments = binary.arguments
                variables = binary.environment
            case .npm(let package):
                let result = try await NpmInstallation.install(
                    package,
                    version: agent.version,
                    stage: stage,
                    runtime: runtime,
                    run: run
                )
                source = result.source
                executable = result.executable
                arguments = package.arguments
                variables = package.environment
            case .unsupported:
                throw AgentInstallation.Failure.unsupportedDistribution
            }
            let javascript: Bool
            if case .npm = source { javascript = true } else { javascript = false }
            _ = try InstallationFiles.executable(executable, in: payload, javascript: javascript)
            let installation = AgentInstallation(
                id: id,
                agentID: agent.id,
                name: agent.name,
                version: agent.version,
                executable: executable,
                arguments: arguments,
                environment: variables,
                source: source,
                installedAt: .now
            )
            try JSONEncoder().encode(Record(installation: installation)).write(
                to: stage.appending(path: "installation.json")
            )
            let lease = try InstallationLock(stage.appending(path: ".lease"), create: true, failure: .unownedPath)
            lease.release()
            try Task.checkCancellation()
            try exclusively {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try InstallationFiles.directory(target.deletingLastPathComponent(), under: root)
                // A same-volume rename is the publication point. Nothing visible points at a partial install.
                guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw AgentInstallation.Failure.alreadyInstalled }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return installation
        } catch {
            try removeOwned(stage, id: id)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    public func installations() throws -> [AgentInstallation] {
        try exclusively(listInstallations)
    }

    private func listInstallations() throws -> [AgentInstallation] {
        var result: [AgentInstallation] = []
        for agent in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where !agent.lastPathComponent.hasPrefix(".") {
            guard InstallationFiles.component(agent.lastPathComponent) else {
                throw AgentInstallation.Failure.invalidMetadata
            }
            try InstallationFiles.directory(agent, under: root)
            for version in try FileManager.default.contentsOfDirectory(at: agent, includingPropertiesForKeys: nil) {
                guard result.count < 4096 else { throw AgentInstallation.Failure.invalidMetadata }
                result.append(try record(at: version))
            }
        }
        return result.sorted { ($0.agentID, $0.version) < ($1.agentID, $1.version) }
    }

    public func acquire(_ installation: AgentInstallation, directory: URL) async throws -> Lease {
        try Task.checkCancellation()
        // The lease, not the operation lock, keeps this version in place while the runtime is prepared.
        let (lock, executable) = try exclusively {
            let version = try checked(installation)
            let lock = try InstallationLock(
                version.appending(path: ".lease"),
                shared: true,
                failure: .installationInUse
            )
            do {
                let executable = try InstallationFiles.executable(
                    installation.executable,
                    in: version.appending(path: "payload"),
                    javascript: installation.toolchain != nil
                )
                return (lock, executable)
            } catch {
                lock.release()
                throw error
            }
        }
        var transferred = false
        defer { if !transferred { lock.release() } }
        var command: AgentCommand
        let diagnostic: String?
        switch installation.source {
        case .binary:
            let shell = await environment.resolve()
            command = AgentCommand(
                executable: executable.path(percentEncoded: false),
                arguments: installation.arguments,
                environment: shell.environment,
                currentDirectory: directory
            )
            diagnostic = shell.diagnostic
        case .npm(_, _, let toolchain, let requirements):
            try NpmInstallation.validateEnvironment(installation.environment)
            let prepared = try await runtime.prepare(toolchain, requirements: requirements)
            command = prepared.agentCommand(script: executable, arguments: installation.arguments, directory: directory)
            diagnostic = prepared.shellDiagnostic
        }
        try Task.checkCancellation()
        command.environment = (command.environment ?? [:]).merging(installation.environment) { _, declared in declared }
        transferred = true
        return Lease(command: command, installation: installation, diagnostic: diagnostic, lock: lock)
    }

    public func remove(_ installation: AgentInstallation) throws {
        try Task.checkCancellation()
        try exclusively {
            let version = try checked(installation)
            let lease = try InstallationLock(version.appending(path: ".lease"), failure: .installationInUse)
            defer { lease.release() }
            try removeOwned(version, id: installation.id)
        }
    }

    /// Holds the operation lock for synchronous steps only: downloads, npm runs and shell captures must not
    /// make parallel launches or another installation fail with `operationInProgress`.
    private func exclusively<T>(_ body: () throws -> T) throws -> T {
        let operation = try beginOperation()
        defer { operation.release() }
        return try body()
    }

    private func beginOperation() throws -> InstallationLock {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try InstallationFiles.directory(root, under: root)
        let marker = root.appending(path: ".owner")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw AgentInstallation.Failure.unownedPath
            }
            do { try Self.ownership.write(to: marker, options: .withoutOverwriting) } catch {
                guard (try? InstallationFiles.read(marker)) == Self.ownership else {
                    throw AgentInstallation.Failure.unownedPath
                }
            }
        }
        guard (try? InstallationFiles.read(marker)) == Self.ownership else {
            throw AgentInstallation.Failure.unownedPath
        }
        return try InstallationLock(root.appending(path: ".operation"), create: true, failure: .operationInProgress)
    }

    private func location(agentID: String, version: String) throws -> URL {
        guard InstallationFiles.component(agentID), !agentID.hasPrefix("."), InstallationFiles.component(version),
            !version.hasPrefix(".")
        else { throw AgentInstallation.Failure.invalidMetadata }
        return root.appending(path: agentID).appending(path: version)
    }

    private func checked(_ installation: AgentInstallation) throws -> URL {
        let url = try location(agentID: installation.agentID, version: installation.version)
        guard try record(at: url) == installation else { throw AgentInstallation.Failure.invalidMetadata }
        return url
    }

    private func record(at url: URL) throws -> AgentInstallation {
        try InstallationFiles.directory(url, under: root)
        let record = try JSONDecoder().decode(
            Record.self,
            from: InstallationFiles.read(url.appending(path: "installation.json"))
        )
        let installation = record.installation
        guard record.formatVersion == 1,
            try location(agentID: installation.agentID, version: installation.version).pathComponents
                == url.standardizedFileURL.resolvingSymlinksInPath().pathComponents,
            try InstallationFiles.read(url.appending(path: ".owner")) == Data(installation.id.uuidString.utf8),
            installation.arguments.allSatisfy({ !$0.contains("\0") }),
            installation.environment.allSatisfy({ key, value in
                !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
            })
        else { throw AgentInstallation.Failure.invalidMetadata }
        return installation
    }

    private func removeOwned(_ directory: URL, id: UUID) throws {
        try InstallationFiles.directory(directory, under: root)
        guard directory.pathComponents.count > root.pathComponents.count,
            try InstallationFiles.read(directory.appending(path: ".owner")) == Data(id.uuidString.utf8)
        else { throw AgentInstallation.Failure.unownedPath }
        try FileManager.default.removeItem(at: directory)
    }

    private static func verify(_ archive: URL, checksum: String) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == checksum.lowercased() else { throw AgentInstallation.Failure.checksumMismatch }
    }

    private struct Record: Codable {
        var formatVersion = 1
        let installation: AgentInstallation
    }
}
