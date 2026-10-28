import ACP
import Foundation
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct AgentCatalogSignInTests {
    @Test func anInstalledSignInPinsItsVersionUntilCompletionWithoutHistory() async throws {
        let fixture = try InstalledMockFixture()
        let suite = "agh-sign-in-catalog-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { fixture.remove(); defaults.removePersistentDomain(forName: suite) }
        let installation = try await fixture.installer.install(fixture.agent(version: "1.0.0"))
        let catalog = catalog(root: fixture.root, installer: fixture.installer, defaults: defaults)
        await catalog.reloadInstallations()
        let flow = try #require(catalog.beginSignIn(installation))
        #expect(catalog.beginSignIn(installation) == nil)
        await flow.prepare()
        await catalog.install(try fixture.agent(version: "2.0.0"))
        #expect(flow.name == "Mock 1.0.0")
        #expect(catalog.latest.first?.version == "2.0.0")
        await catalog.remove(installation)
        #expect(
            catalog.failures[installation.agentID] == AgentInstallation.Failure.installationInUse.localizedDescription
        )
        await flow.signIn(with: "mock-login")
        #expect(flow.state == .completed)
        #expect(try await fixture.library.history().isEmpty)
        #expect(try await fixture.library.store().agentInstalls().isEmpty)
        await catalog.remove(installation)
        #expect(catalog.failures.isEmpty)
        #expect(catalog.installations.map(\.version) == ["2.0.0"])
        await catalog.closeSignIn(flow)
        #expect(catalog.signIn == nil)
    }

    @Test func localSignInUsesTheCapturedEnvironmentAndAStaleCloseCannotDismissANewerFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-local-sign-in-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "agh-sign-in-catalog-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let marker = root.appending(path: "environment")
        let catalog = catalog(
            root: root,
            installer: AgentInstaller(root: root.appending(path: "Agents")),
            defaults: defaults
        )
        catalog.addCustom(
            name: "Local",
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' "$SIGN_IN_TEST" > "$1"; read line; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'; while read line; do :; done"#,
                "sh", marker.path,
            ]
        )
        let local = try #require(catalog.localAgents.first)
        let first = try #require(catalog.beginSignIn(local))
        await first.prepare()
        #expect(first.state == .ready)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "login-shell-value")
        await catalog.closeSignIn(first)
        #expect(first.state == .closed)
        let second = try #require(catalog.beginSignIn(local))
        await catalog.closeSignIn(first)
        #expect(catalog.signIn === second)
        await catalog.closeSignIn(second)
        catalog.remove(local)
        #expect(catalog.beginSignIn(local) == nil)
    }

    private func catalog(root: URL, installer: AgentInstaller, defaults: UserDefaults) -> AgentCatalog {
        AgentCatalog(
            registry: AgentRegistry.Client(cacheDirectory: root.appending(path: "cache")) { _ in
                .init(status: 200, data: Data(#"{"version":"1.0.0","agents":[]}"#.utf8))
            },
            installer: installer,
            defaults: defaults,
            environment: { _ in ["PATH": "/usr/bin:/bin", "SIGN_IN_TEST": "login-shell-value"] },
            probe: { _ in throw CancellationError() },
            checkNode: { _ in throw NodeRuntime.Failure.missingNode }
        )
    }
}
