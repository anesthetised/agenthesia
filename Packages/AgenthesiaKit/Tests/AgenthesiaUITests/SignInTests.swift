import ACP
import AgentRuntime
import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The sign-in panel, its terminal sheet and the window model behind them (ADR-0033).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SignInTests {
    @Test func rowsListEveryMethodAndMarkTheUnsupported() {
        let rows = SignInMethodRow.rows([
            .agent(.init(id: "browser", name: "ChatGPT", description: "Opens the browser")),
            .terminal(.init(id: "login", name: "Claude Subscription", args: ["--cli"])),
            .unknown(["id": "env", "name": "API key", "type": "env_var"]),
            .unknown(["type": "future"]),
        ])
        #expect(
            rows == [
                .init(
                    id: "browser",
                    name: "ChatGPT",
                    detail: "Opens the browser",
                    opensTerminal: false,
                    isSupported: true
                ),
                .init(id: "login", name: "Claude Subscription", detail: nil, opensTerminal: true, isSupported: true),
                .init(
                    id: "env",
                    name: "API key",
                    detail: "Agenthesia does not support this method.",
                    opensTerminal: false,
                    isSupported: false
                ),
                .init(
                    id: "unknown-3",
                    name: "Unknown method",
                    detail: "Agenthesia does not support this method.",
                    opensTerminal: false,
                    isSupported: false
                ),
            ]
        )
    }

    @Test(arguments: [false, true]) func panelFitsNarrowWindows(continuing: Bool) throws {
        let panel = SignInPanel(
            agentName: "Claude",
            signIn: .init(
                methods: [
                    .terminal(.init(id: "a", name: "Claude Subscription", description: "Use Claude subscription")),
                    .agent(.init(id: "b", name: "Gateway")),
                ],
                pending: "a",
                message: "Claude still requires sign-in."
            ),
            continuing: continuing,
            onSignIn: { _ in },
            onCancel: {}
        )
        let host = NSHostingView(rootView: panel.frame(width: 480))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 100)
        #expect(host.fittingSize.width <= 480)
    }

    private func mockAgent() throws -> String {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        return try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ).path
    }

    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func clearingTheSheetCancelsARunningSignInOrHidesAFailedOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-sign-in-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionManager(
            library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
        )
        sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
        let model = SessionWindowModel(sessions: sessions)
        model.start(
            directory: directory,
            executable: try mockAgent(),
            arguments: ["--auth", "--auth-file", directory.appending(path: "signed-in").path(percentEncoded: false)]
        )
        let owner = try #require(model.owner)
        await owner.startup?.value
        #expect(model.signIn?.methods.count == 2)
        #expect(!model.canDiscard && !model.canMerge)

        model.signIn(with: "mock-terminal")
        await eventually { model.signInTerminal != nil }
        model.signInTerminal = nil
        await eventually { owner.signInTerminal == nil && model.signIn?.pending == nil }

        model.signIn(with: "mock-terminal")
        await eventually { model.signInTerminal != nil }
        let terminal = try #require(model.signInTerminal)
        terminal.write(Data("no\n".utf8))
        await eventually { terminal.exitMessage != nil && model.signIn?.pending == nil }
        #expect(model.signInTerminal === terminal)
        model.signInTerminal = nil
        #expect(model.signInTerminal == nil)

        model.signIn(with: "mock-login")
        await eventually { model.signIn == nil && owner.controller?.status == .idle }
        await sessions.closeAll()
    }

    @Test func theTerminalShowsOutputAndSendsTyping() async throws {
        let process = try TerminalProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "echo ready; read line; echo \"got:$line\""]
            )
        )
        let terminal = SignInTerminal(title: "Test", process: process)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: TerminalHost(terminal: terminal).frame(width: 640, height: 400))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(Self.terminalView(in: host))
        #expect(window.firstResponder === view)

        func text() -> String {
            view.selectAll()
            return view.getSelection() ?? ""
        }
        await eventually { text().contains("ready") }
        view.terminalDelegate?.send(source: view, data: Array("hello\r".utf8)[...])
        #expect(await terminal.waitForExit() == .exited(0))
        await eventually { text().contains("got:hello") }
        window.contentView = nil
    }

    private static func terminalView(in view: NSView) -> TerminalView? {
        if let terminal = view as? TerminalView { return terminal }
        return view.subviews.lazy.compactMap(terminalView(in:)).first
    }
}
