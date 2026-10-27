public import Foundation

/// Prerequisites for npm agents. Uses user-owned tools without installing or modifying them.
public struct NodeRuntime: Sendable {
    public enum Tool: String, Codable, Sendable { case node, npm }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case missingNode, missingNpm, unsupportedNpm, unsupportedNodePath, runtimeChanged
        case probeFailed(Tool), timedOut(Tool), invalidOutput(Tool), invalidRequirement(Tool)
        case incompatible(Tool, version: String, required: String)

        public var errorDescription: String? {
            let reason: String
            switch self {
            case .missingNode: reason = "Node.js is unavailable. Install or restore Node.js in your login-shell PATH."
            case .missingNpm: reason = "npm is unavailable. Install or restore npm for your Node.js installation."
            case .unsupportedNpm:
                reason =
                    "The npm wrapper could not be resolved. Expose a standard npm installation in PATH or beside Node.js."
            case .unsupportedNodePath:
                reason =
                    "The Node.js directory contains a colon and cannot be pinned in PATH. Select an installation in another directory."
            case .runtimeChanged: reason = "The selected Node.js or npm installation changed. Select the runtime again."
            case .probeFailed(let tool): reason = "\(tool.rawValue) could not run. Repair the selected installation."
            case .timedOut(let tool):
                reason = "\(tool.rawValue) did not respond in time. Check its installation and shell setup."
            case .invalidOutput(let tool):
                reason = "\(tool.rawValue) returned an invalid or oversized response. Check its installation."
            case .invalidRequirement(let tool):
                reason =
                    "The package declares an invalid \(tool.rawValue) version requirement. Choose another package version."
            case .incompatible(let tool, let version, let required):
                reason = "\(tool.rawValue) \(version) does not satisfy \(required). Select a compatible installation."
            }
            return reason + " Then use Check Again."
        }
    }

    /// npm engine ranges, supplied by the exact package's metadata in the installer.
    public struct Requirements: Codable, Equatable, Sendable {
        public var node: String?
        public var npm: String?

        public init(node: String? = nil, npm: String? = nil) {
            self.node = node
            self.npm = npm
        }
    }

    /// Safe to persist with an installation. Does not contain the user's environment or credentials.
    public struct Toolchain: Codable, Equatable, Sendable {
        public let node: String
        public let npm: String
        public let nodeVersion: String
        public let npmVersion: String
    }

    /// A checked snapshot for one operation. Call `prepare` again before a later installation or launch.
    public struct Prepared: Sendable {
        public let toolchain: Toolchain
        public let environment: [String: String]
        public let shellDiagnostic: String?

        public func npmCommand(arguments: [String], directory: URL) -> AgentCommand {
            AgentCommand(
                executable: toolchain.node,
                arguments: [toolchain.npm] + arguments,
                environment: environment,
                currentDirectory: directory
            )
        }

        /// The installer resolves the package's JavaScript bin entry; no npx or shim runs at launch.
        public func agentCommand(script: URL, arguments: [String] = [], directory: URL) -> AgentCommand {
            AgentCommand(
                executable: toolchain.node,
                arguments: [script.path(percentEncoded: false)] + arguments,
                environment: environment,
                currentDirectory: directory
            )
        }
    }

    private let environment: ShellEnvironment
    private let run: @Sendable (AgentCommand) async -> CommandOutput

    public init(environment: ShellEnvironment = .shared) {
        self.environment = environment
        run = { await CommandOutput.capture($0) }
    }

    init(environment: ShellEnvironment, run: @escaping @Sendable (AgentCommand) async -> CommandOutput) {
        self.environment = environment
        self.run = run
    }

    public func discover(requirements: Requirements = .init(), refresh: Bool = false) async throws -> Prepared {
        try Task.checkCancellation()
        try validate(requirements)
        let shell = refresh ? await environment.refresh() : await environment.resolve()
        try Task.checkCancellation()
        let variables = Self.cleanEnvironment(shell.environment)
        guard let entry = Self.find("node", in: variables) else { throw Failure.missingNode }
        let node = try await inspectNode(entry, environment: variables)
        guard Self.isExecutable(node.executable), URL(filePath: node.executable).lastPathComponent == "node" else {
            throw Failure.invalidOutput(.node)
        }
        // Resolve npm's symlink directly; for a version-manager shim use npm beside the actual Node.
        let candidates = [
            Self.find("npm", in: variables),
            URL(filePath: node.executable).deletingLastPathComponent()
                .appending(path: "npm").path(percentEncoded: false),
        ].compactMap { $0 }
        guard let npm = candidates.compactMap(Self.npmCLI).first else {
            throw candidates.contains(where: Self.isExecutable) ? Failure.unsupportedNpm : Failure.missingNpm
        }
        return try await check(node: node.executable, npm: npm, expected: nil, requirements: requirements, shell: shell)
    }

    /// Revalidates saved paths and versions; never silently falls back to a different installed runtime.
    public func prepare(_ toolchain: Toolchain, requirements: Requirements = .init()) async throws -> Prepared {
        try Task.checkCancellation()
        try validate(requirements)
        let shell = await environment.resolve()
        try Task.checkCancellation()
        return try await check(
            node: toolchain.node,
            npm: toolchain.npm,
            expected: toolchain,
            requirements: requirements,
            shell: shell
        )
    }

    private func check(
        node: String,
        npm: String,
        expected: Toolchain?,
        requirements: Requirements,
        shell: ShellEnvironment.Resolution
    ) async throws -> Prepared {
        guard Self.isExecutable(node) else { throw Failure.missingNode }
        guard let canonicalNpm = Self.npmCLI(npm) else { throw Failure.missingNpm }
        let canonicalNode = URL(filePath: node).resolvingSymlinksInPath().path(percentEncoded: false)
        if let expected, canonicalNode != expected.node || canonicalNpm != expected.npm { throw Failure.runtimeChanged }
        var variables = Self.cleanEnvironment(shell.environment)
        let bin = URL(filePath: canonicalNode).deletingLastPathComponent().path(percentEncoded: false)
        guard !bin.contains(":") else { throw Failure.unsupportedNodePath }
        let paths = (variables["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != bin }
        variables["PATH"] = ([bin] + paths).joined(separator: ":")
        variables["npm_node_execpath"] = canonicalNode
        variables["npm_execpath"] = canonicalNpm
        let inspected = try await inspectNode(canonicalNode, environment: variables)
        guard inspected.executable == canonicalNode else { throw Failure.runtimeChanged }
        let encoded = String(decoding: try JSONEncoder().encode(requirements), as: UTF8.self)
        let metadata: NpmInfo = try await json(
            command(canonicalNode, ["--eval", Self.npmProbe, canonicalNpm, encoded], variables),
            tool: .npm
        )
        if let invalid = metadata.invalidRequirement { throw Failure.invalidRequirement(invalid) }
        guard metadata.toolchainCompatible else {
            throw Failure.incompatible(.node, version: inspected.version, required: metadata.nodeRequirement)
        }
        guard metadata.nodeCompatible else {
            throw Failure.incompatible(.node, version: inspected.version, required: requirements.node ?? "*")
        }
        guard metadata.npmCompatible else {
            throw Failure.incompatible(.npm, version: metadata.version, required: requirements.npm ?? "*")
        }
        let version = try await output(command(canonicalNode, [canonicalNpm, "--version"], variables), tool: .npm)
        guard
            String(data: version, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == metadata.version
        else {
            throw Failure.invalidOutput(.npm)
        }
        let toolchain = Toolchain(
            node: canonicalNode,
            npm: canonicalNpm,
            nodeVersion: inspected.version,
            npmVersion: metadata.version
        )
        if let expected, toolchain != expected { throw Failure.runtimeChanged }
        return Prepared(toolchain: toolchain, environment: variables, shellDiagnostic: shell.diagnostic)
    }

    private func inspectNode(_ path: String, environment: [String: String]) async throws -> NodeInfo {
        let info: NodeInfo = try await json(command(path, ["--eval", Self.nodeProbe], environment), tool: .node)
        guard info.executable.hasPrefix("/"), !info.executable.contains("\0"),
            info.version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil
        else { throw Failure.invalidOutput(.node) }
        return info
    }

    private func command(_ executable: String, _ arguments: [String], _ environment: [String: String]) -> AgentCommand {
        AgentCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: URL(filePath: environment["HOME"] ?? NSHomeDirectory())
        )
    }

    private func json<T: Decodable>(_ command: AgentCommand, tool: Tool) async throws -> T {
        let data = try await output(command, tool: tool)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw Failure.invalidOutput(tool) }
        return decoded
    }

    private func output(_ command: AgentCommand, tool: Tool) async throws -> Data {
        try Task.checkCancellation()
        let result = await run(command)
        try Task.checkCancellation()
        switch result {
        case .success(let data, 0): return data
        case .timedOut: throw Failure.timedOut(tool)
        case .tooMuchOutput: throw Failure.invalidOutput(tool)
        case .launchFailed, .success: throw Failure.probeFailed(tool)
        }
    }

    private func validate(_ requirements: Requirements) throws {
        for (tool, range) in [(Tool.node, requirements.node), (.npm, requirements.npm)] {
            if let range, range.utf8.count > 4096 || range.contains("\0") { throw Failure.invalidRequirement(tool) }
        }
    }

    private static func cleanEnvironment(_ source: [String: String]) -> [String: String] {
        var result = source
        // Relative hooks and PATH entries can select project-owned code during prerequisite checks.
        result.removeValue(forKey: "NODE_OPTIONS")
        result.removeValue(forKey: "NODE_PATH")
        result["PATH"] = (source["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.joined(
            separator: ":"
        )
        return result
    }

    private static func find(_ name: String, in environment: [String: String]) -> String? {
        (environment["PATH"] ?? "").split(separator: ":").map {
            URL(filePath: String($0)).appending(path: name).path(percentEncoded: false)
        }.first(where: isExecutable)
    }

    private static func isExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isExecutableFile(atPath: path) else {
            return false
        }
        return
            (try? URL(filePath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
            .isRegularFile) == true
    }

    private static func npmCLI(_ path: String) -> String? {
        let url = URL(filePath: path).resolvingSymlinksInPath()
        guard url.lastPathComponent == "npm-cli.js", isExecutable(url.path(percentEncoded: false)) else { return nil }
        return url.path(percentEncoded: false)
    }

    private struct NodeInfo: Decodable { let executable: String; let version: String }
    private struct NpmInfo: Decodable {
        let version: String
        let nodeRequirement: String
        let toolchainCompatible: Bool
        let nodeCompatible: Bool
        let npmCompatible: Bool
        let invalidRequirement: Tool?
    }

    static let nodeProbe = "console.log(JSON.stringify({executable: process.execPath, version: process.versions.node}))"

    // Use the selected npm's own dependency and range semantics; no bundled JS or package downloads.
    static let npmProbe = #"""
        const fs = require('fs');
        const path = require('path');
        const cli = fs.realpathSync(process.argv[1]);
        const root = path.dirname(path.dirname(cli));
        const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
        if (pkg.name !== 'npm' || fs.realpathSync(path.resolve(root, pkg.bin.npm)) !== cli) {
            throw new Error('Not a standard npm installation');
        }
        const semver = require(require.resolve('semver', {paths: [root]}));
        const required = JSON.parse(process.argv[2]);
        const nodeRequirement = (pkg.engines && pkg.engines.node) || '*';
        if (!semver.valid(pkg.version) || !semver.validRange(nodeRequirement)) {
            throw new Error('Invalid npm metadata');
        }
        const invalidRequirement = ['node', 'npm'].find(k =>
            required[k] != null && semver.validRange(required[k]) === null);
        console.log(JSON.stringify({
            version: pkg.version, nodeRequirement, invalidRequirement,
            toolchainCompatible: semver.satisfies(process.versions.node, nodeRequirement),
            nodeCompatible: required.node == null || semver.satisfies(process.versions.node, required.node),
            npmCompatible: required.npm == null || semver.satisfies(pkg.version, required.npm)
        }));
        """#
}
