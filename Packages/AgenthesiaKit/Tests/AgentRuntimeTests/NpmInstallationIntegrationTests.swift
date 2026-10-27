import CryptoKit
import Foundation
import Testing

@testable import AgentRuntime

/// Optional host integration. All registry traffic and package writes stay in this temporary fixture.
@Suite(.timeLimit(.minutes(1))) struct NpmInstallationIntegrationTests {
    @Test func realNpmInstallsAPinnedPackageWithoutRunningItsLifecycleScript() async throws {
        let paths =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/node") }),
            paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/npm") })
        else { return }
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let shell = ShellEnvironment(capture: {
            .init(
                environment: [
                    "PATH": paths.joined(separator: ":"), "HOME": fixture.root.path, "TMPDIR": fixture.root.path,
                ],
                diagnostic: nil
            )
        })
        let runtime = NodeRuntime(environment: shell)
        let prepared = try await runtime.discover()
        let package = fixture.root.appending(path: "package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let metadata =
            #"{"name":"agenthesia-install-fixture","version":"1.0.0","bin":{"agenthesia-install-fixture":"entry.js"},"scripts":{"postinstall":"node postinstall.js"},"engines":{"node":">=18"}}"#
        try Data(metadata.utf8).write(to: package.appending(path: "package.json"))
        try Data("#!/usr/bin/env node\nconsole.log('installed fixture');\n".utf8).write(
            to: package.appending(path: "entry.js")
        )
        try Data("require('fs').writeFileSync(require('path').join(process.env.HOME, 'script-ran'), 'bad')".utf8).write(
            to: package.appending(path: "postinstall.js")
        )
        let tarball = fixture.root.appending(path: "fixture.tgz")
        let packed = await CommandOutput.capture(
            .init(executable: "/usr/bin/tar", arguments: ["-czf", tarball.path, "-C", fixture.root.path, "package"])
        )
        #expect(packed == .success(Data(), 0))
        let integrity = "sha512-" + Data(SHA512.hash(data: try Data(contentsOf: tarball))).base64EncodedString()
        let portFile = fixture.root.appending(path: "port")
        let server = try AgentProcess(
            launching: .init(
                executable: prepared.toolchain.node,
                arguments: [
                    "--eval", Self.server, package.appending(path: "package.json").path, tarball.path, portFile.path,
                    integrity,
                ],
                environment: prepared.environment,
                currentDirectory: fixture.root
            )
        )
        do {
            let port = try await waitForChildPID(at: portFile)
            let registry = "http://127.0.0.1:\(port)/"
            let installer = AgentInstaller(
                root: fixture.root.appending(path: "Agents"),
                environment: shell,
                runtime: runtime,
                download: { _, _ in Issue.record("Unexpected binary download") },
                run: { command in
                    var local = command
                    local.arguments = command.arguments.map {
                        $0.hasPrefix("--registry=") ? "--registry=\(registry)" : $0
                    }
                    return await CommandOutput.capture(local, timeout: .seconds(20), limit: 1_048_576)
                }
            )
            let agent = try JSONDecoder().decode(
                AgentRegistry.Agent.self,
                from: Data(
                    #"{"id":"fixture","name":"Fixture","version":"1.0.0","description":"Local test","distribution":{"npx":{"package":"agenthesia-install-fixture"}}}"#
                        .utf8
                )
            )
            let installation = try await installer.install(agent)
            let lease = try await installer.acquire(installation, directory: fixture.root)
            #expect(await CommandOutput.capture(lease.command) == .success(Data("installed fixture\n".utf8), 0))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "script-ran").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".npm").path))
            let payload = fixture.root.appending(path: "Agents/fixture/1.0.0/payload")
            let lockfile = try String(contentsOf: payload.appending(path: "package-lock.json"), encoding: .utf8)
            #expect(lockfile.contains(integrity))
            #expect(!lockfile.contains(".staging-"))
            lease.release()
            try await installer.remove(installation)
            _ = await server.terminate()
        } catch {
            _ = await server.terminate()
            throw error
        }
    }

    private static let server = #"""
        const fs = require('fs');
        const http = require('http');
        const pkg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        const tarball = fs.readFileSync(process.argv[2]);
        const server = http.createServer((req, res) => {
          if (req.url === '/fixture.tgz') {
            res.writeHead(200, {'Content-Type': 'application/octet-stream'});
            return res.end(tarball);
          }
          const version = {...pkg, dist: {tarball: `http://127.0.0.1:${server.address().port}/fixture.tgz`, integrity: process.argv[4]}};
          res.writeHead(200, {'Content-Type': 'application/json'});
          res.end(JSON.stringify({name: pkg.name, 'dist-tags': {latest: pkg.version}, versions: {[pkg.version]: version}}));
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[3], String(server.address().port)));
        """#
}
