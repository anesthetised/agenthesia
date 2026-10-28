import AppKit
import SwiftUI
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentSettingsSignInTests {
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-settings-sign-in-\(UUID())")
        let suite = "agh-settings-sign-in-\(UUID())"
        let defaults: UserDefaults
        let catalog: AgentCatalog

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            catalog = AgentCatalog(
                registry: AgentRegistry.Client(cacheDirectory: root.appending(path: "cache")) { _ in
                    .init(status: 200, data: Data(#"{"version":"1.0.0","agents":[]}"#.utf8))
                },
                installer: AgentInstaller(root: root.appending(path: "Agents")),
                defaults: defaults,
                environment: { _ in ["PATH": "/usr/bin:/bin"] },
                probe: { _ in throw CancellationError() },
                checkNode: { _ in throw NodeRuntime.Failure.missingNode }
            )
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ).path(percentEncoded: false)
            catalog.addCustom(
                name: "Mock",
                executable: binary,
                arguments: ["--auth", "--auth-file", root.appending(path: "signed-in").path]
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        func flow() throws -> AgentSignIn {
            let agent = try #require(catalog.localAgents.first)
            return try #require(catalog.beginSignIn(agent))
        }
    }

    @Test func signInSheetHostsMethodsAndCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = try fixture.flow()
        await flow.prepare()
        let host = NSHostingView(rootView: AgentSignInSheet(flow: flow, onDone: {}))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 520)
        #expect(host.fittingSize.height > 100)
        await flow.signIn(with: "mock-login")
        #expect(flow.state == .completed)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 520)
        await fixture.catalog.closeSignIn(flow)
    }

    @Test func closingTheSettingsWindowClosesItsSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = try fixture.flow()
        await flow.prepare()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(catalog: fixture.catalog))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.close()
        try await eventually { fixture.catalog.signIn == nil }
        #expect(flow.state == .closed)
    }

    @Test func quittingWaitsForSignInEvenWithoutAnySession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = try fixture.flow()
        await flow.prepare()
        let signingIn = Task { await flow.signIn(with: "mock-terminal") }
        try await eventually { flow.terminal != nil }
        let delegate = SessionApplicationDelegate()
        delegate.catalog = fixture.catalog
        delegate.sessions = SessionManager(
            library: SessionLibrary(databaseURL: fixture.root.appending(path: "history.sqlite"))
        )
        var replies = 0
        delegate.terminationReply = { _ in
            #expect(flow.state == .closed)
            #expect(fixture.catalog.signIn == nil)
            replies += 1
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await eventually { replies == 1 }
        await signingIn.value
        #expect(try await delegate.sessions.library.history().isEmpty)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
