import Foundation

/// Uses the user's checked npm CLI in a private prefix, with no lifecycle scripts or global configuration.
enum NpmInstallation {
    static func install(
        _ distribution: AgentRegistry.Package,
        version: String,
        stage: URL,
        runtime: NodeRuntime,
        run: @Sendable (AgentCommand) async -> CommandOutput
    ) async throws -> (source: AgentInstallation.Source, executable: String) {
        let stage = try InstallationFiles.physicalDirectory(stage)
        let (name, version) = try reference(distribution.package, version: version)
        try validateEnvironment(distribution.environment)
        let payload = stage.appending(path: "payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let tools = try await runtime.discover()
        let flags = try configuration(in: stage)
        let query = command(tools, arguments: ["view", "\(name)@\(version)", "--json"] + flags, payload: payload)
        let metadata = try decode(try await output(query, run: run))
        guard metadata.name == name, metadata.version == version else { throw AgentInstallation.Failure.invalidPackage }
        let bin = try metadata.entrypoint()
        let prepared = try await runtime.prepare(tools.toolchain, requirements: metadata.engines ?? .init())
        let manifest = Manifest(name: "agenthesia-install", version: "1.0.0", dependencies: [name: version])
        try JSONEncoder().encode(manifest).write(to: payload.appending(path: "package.json"))
        let install = command(prepared, arguments: ["install"] + flags, payload: payload)
        _ = try await output(install, run: run)
        try Task.checkCancellation()
        let relative = "node_modules/\(name)/\(bin)"
        let package = payload.appending(path: "node_modules/\(name)")
        try InstallationFiles.directory(package, under: payload.standardizedFileURL.resolvingSymlinksInPath())
        let installed = try decode(InstallationFiles.read(package.appending(path: "package.json")))
        guard installed.name == name, installed.version == version, installed.engines == metadata.engines,
            try installed.entrypoint() == bin
        else { throw AgentInstallation.Failure.invalidPackage }
        try validateLockfile(in: payload, name: name, version: version)
        do {
            let script = try InstallationFiles.executable(relative, in: payload, javascript: true)
            let handle = try FileHandle(forReadingFrom: script)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 512) ?? Data()
            let shebang = String(decoding: prefix.prefix(while: { $0 != 10 }), as: UTF8.self)
            guard
                ["js", "cjs", "mjs"].contains(script.pathExtension)
                    || (shebang.hasPrefix("#!") && shebang.contains("node"))
            else {
                throw AgentInstallation.Failure.invalidExecutable
            }
        } catch { throw AgentInstallation.Failure.npmFailed }
        for name in ["npm-cache", "npm-userconfig", "npm-globalconfig"] {
            let file = stage.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        return (
            .npm(
                package: name,
                version: version,
                toolchain: prepared.toolchain,
                requirements: metadata.engines ?? .init()
            ), relative
        )
    }

    static func validateEnvironment(_ environment: [String: String]) throws {
        let pinned = ["PATH", "NODE_OPTIONS", "NODE_PATH", "NPM_EXECPATH", "NPM_NODE_EXECPATH"]
        guard
            !environment.keys.contains(where: {
                pinned.contains($0.uppercased()) || $0.lowercased().hasPrefix("npm_config_")
            })
        else {
            throw AgentInstallation.Failure.invalidPackage
        }
    }

    static func reference(_ package: String, version: String) throws -> (String, String) {
        let separator = package.lastIndex(of: "@")
        let name: String
        let pinned: String
        if let separator, separator != package.startIndex {
            name = String(package[..<separator])
            pinned = String(package[package.index(after: separator)...])
        } else {
            name = package
            pinned = version
        }
        let namePattern = #"(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*"#
        let versionPattern =
            #"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[a-zA-Z0-9.-]+)?(?:\+[a-zA-Z0-9.-]+)?"#
        guard name.range(of: namePattern, options: .regularExpression) == name.startIndex..<name.endIndex,
            pinned.range(of: versionPattern, options: .regularExpression) == pinned.startIndex..<pinned.endIndex
        else { throw AgentInstallation.Failure.invalidPackage }
        return (name, pinned)
    }

    private static func configuration(in stage: URL) throws -> [String] {
        let user = stage.appending(path: "npm-userconfig")
        let global = stage.appending(path: "npm-globalconfig")
        try Data().write(to: user, options: .withoutOverwriting)
        try Data().write(to: global, options: .withoutOverwriting)
        return [
            "--ignore-scripts=true", "--global=false", "--package-lock=true", "--engine-strict=true",
            "--audit=false", "--fund=false", "--update-notifier=false", "--loglevel=error",
            "--registry=https://registry.npmjs.org/", "--userconfig=\(user.path(percentEncoded: false))",
            "--globalconfig=\(global.path(percentEncoded: false))",
            "--cache=\(stage.appending(path: "npm-cache").path(percentEncoded: false))",
            "--prefix=\(stage.appending(path: "payload").path(percentEncoded: false))",
            "--bin-links=true", "--include=prod", "--include=optional", "--include=peer", "--omit=dev",
        ]
    }

    private static func command(_ prepared: NodeRuntime.Prepared, arguments: [String], payload: URL) -> AgentCommand {
        var command = prepared.npmCommand(arguments: arguments, directory: payload)
        command.environment = prepared.environment.filter {
            !$0.key.lowercased().hasPrefix("npm_config_") && $0.key != "NODE_ENV"
        }
        return command
    }

    private static func output(
        _ command: AgentCommand,
        run: @Sendable (AgentCommand) async -> CommandOutput
    ) async throws -> Data {
        try Task.checkCancellation()
        let result = await run(command)
        try Task.checkCancellation()
        guard case .success(let bytes, 0) = result else {
            if case .cancelled = result { throw CancellationError() }
            throw AgentInstallation.Failure.npmFailed
        }
        return bytes
    }

    private static func decode(_ bytes: Data) throws -> Metadata {
        guard bytes.count <= 1_048_576, let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes) else {
            throw AgentInstallation.Failure.invalidPackage
        }
        return metadata
    }

    private static func validateLockfile(in directory: URL, name: String, version: String) throws {
        let data = try InstallationFiles.read(directory.appending(path: "package-lock.json"), limit: 8_388_608)
        guard let lock = try? JSONDecoder().decode(Lockfile.self, from: data), [2, 3].contains(lock.lockfileVersion),
            lock.packages[""]?.dependencies?[name] == version,
            let package = lock.packages["node_modules/\(name)"], package.version == version,
            package.link != true, package.integrity?.isEmpty == false
        else { throw AgentInstallation.Failure.invalidPackage }
    }

    private struct Manifest: Encodable {
        let name: String
        let version: String
        let dependencies: [String: String]
        let `private` = true
    }

    private struct Lockfile: Decodable {
        let lockfileVersion: Int
        let packages: [String: Package]
        struct Package: Decodable {
            let version: String?
            let dependencies: [String: String]?
            let integrity: String?
            let link: Bool?
        }
    }

    private struct Metadata: Decodable {
        let name: String
        let version: String
        let engines: NodeRuntime.Requirements?
        let bin: Bin?

        func entrypoint() throws -> String {
            let path: String
            switch bin {
            case .single(let entry): path = entry
            case .multiple(let entries):
                if Set(entries.values).count == 1, let first = entries.values.first {
                    path = first
                } else if let named = entries[String(name.split(separator: "/").last ?? "")] {
                    path = named
                } else {
                    throw AgentInstallation.Failure.invalidPackage
                }
            case nil: throw AgentInstallation.Failure.invalidPackage
            }
            guard let relative = try? AgentArchive.relativePath(path), !relative.isEmpty else {
                throw AgentInstallation.Failure.invalidPackage
            }
            return relative
        }
    }

    private enum Bin: Decodable {
        case single(String), multiple([String: String])
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let path = try? value.decode(String.self) {
                self = .single(path)
            } else {
                self = .multiple(try value.decode([String: String].self))
            }
        }
    }
}
