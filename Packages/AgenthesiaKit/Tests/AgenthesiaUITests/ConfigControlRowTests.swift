import ACP
import AppKit
import Foundation
import Observation
import Persistence
import SwiftUI
import TestSupport
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The composer's control row: which options overflow into `…`, and toggle pills going through the agent.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ConfigControlRowTests {
    private func option(_ id: String, _ category: ACP.ConfigOptionCategory? = nil) -> ACP.ConfigOption {
        .init(id: id, name: id, category: category, value: .select(currentValue: "a", options: .flat([])))
    }

    @Test func otherOptionsOverflowFromTheEndBeforeModeModelAndEffort() {
        let options = [
            option("mode", .mode), .init(id: "fast", name: "Fast", value: .boolean(currentValue: true)),
            option("model", .model), option("other"), option("effort", .thoughtLevel),
        ]
        func overflow(_ count: Int) -> [String] {
            ConfigControlRow.split(options, overflowing: count).overflow.map(\.id)
        }
        #expect(ConfigControlRow.split(options, overflowing: 0).shown.map(\.id) == options.map(\.id))
        #expect(overflow(1) == ["other"])
        #expect(overflow(2) == ["fast", "other"])
        #expect(overflow(3) == ["fast", "other", "effort"])
        #expect(overflow(4) == ["fast", "model", "other", "effort"])
        #expect(overflow(5) == options.map(\.id))
        #expect(ConfigControlRow.split(options, overflowing: 3).shown.map(\.id) == ["mode", "model"])
    }

    /// Wide, every pill shows; narrow, the last ones move into `…`, which never leaves the row's bounds.
    @Test func aSessionsPillsMoveIntoTheOverflowMenuWhenTheRowIsNarrow() async throws {
        let fixture = try await Fixture()
        let wide = try await labels(of: SessionConfigControls(session: fixture.controller), width: 600)
        #expect(wide.labels == ["Small", "Medium"])
        let narrow = try await labels(of: SessionConfigControls(session: fixture.controller), width: 150)
        #expect(narrow.labels.last == "…")
        #expect(narrow.labels.count < 3)
        let tiny = try await labels(of: SessionConfigControls(session: fixture.controller), width: 40)
        #expect(tiny.labels == ["…"] && tiny.fits)
        await fixture.remove()
    }

    /// A toggle pill shows the confirmed value and sends the flipped one; the pill turns on only once the agent agrees.
    @Test func aBooleanOptionIsToggledThroughTheAgent() async throws {
        let fixture = try await Fixture()
        let controller = fixture.controller
        func fast() -> ACP.ConfigOption.Value? { controller.transcript.configOptions.first { $0.id == "fast" }?.value }
        #expect(fast() == .boolean(currentValue: false))
        SessionConfigControls(session: controller).change("fast", to: .boolean(true))
        #expect(fast() == .boolean(currentValue: false))
        try await waitUntil { fast() == .boolean(currentValue: true) && !controller.isChangingConfig }
        #expect(controller.configError == nil)
        await fixture.remove()
    }

    /// A pick during a turn shows after the confirmed value; the mode pill also says a waiting request stays.
    @Test func aPendingValueFollowsTheConfirmedOne() async throws {
        let choices = ACP.ConfigSelectOptions.flat([
            .init(value: "high", name: "High"), .init(value: "max", name: "Max"),
        ])
        let options: [ACP.ConfigOption] = [
            .init(
                id: "effort",
                name: "Effort",
                category: .thoughtLevel,
                value: .select(currentValue: "high", options: choices)
            ),
            .init(id: "fast", name: "Fast mode", value: .boolean(currentValue: false)),
        ]
        let row = ConfigControlRow(options: options, pending: ["effort": .select("max"), "fast": .boolean(true)]) {
            _,
            _ in
        }
        #expect(try await labels(of: row, width: 600).labels == ["High → Max, next turn"])
        #expect(try await labels(of: ConfigControlRow(options: options) { _, _ in }, width: 600).labels == ["High"])
        #expect(ConfigSelectMenu.label("Fast mode", pending: "On") == "Fast mode → On, next turn")
        let mode = ACP.ConfigOption(
            id: "mode",
            name: "Mode",
            category: .mode,
            value: .select(currentValue: "high", options: choices)
        )
        let pill = ConfigSelectMenu(
            option: mode,
            choices: choices,
            selected: "high",
            pending: "Max",
            addendum: "Changing the mode does not answer the waiting request."
        ) { _ in }
        #expect(
            pill.accessibilityText
                == "Mode: High → Max, next turn. Changing the mode does not answer the waiting request."
        )
    }

    /// A click on a toggle flips what the pill shows: a second click drops a pending change.
    @Test func aSecondClickOnAToggleDropsItsPendingChange() {
        #expect(ConfigControlRow.toggled(false, pending: nil))
        #expect(!ConfigControlRow.toggled(false, pending: .boolean(true)))
        #expect(ConfigControlRow.toggled(true, pending: .boolean(false)))
    }

    /// The mode pill's help names the waiting request only while one waits.
    @Test func theModeNoteFollowsAWaitingPermissionRequest() async throws {
        let fixture = try await Fixture()
        let controller = fixture.controller
        let agentID = try #require(controller.session.agentSessionID)
        #expect(SessionConfigControls(session: controller).modeNote == nil)
        try await controller.submit([.init(text: "slow")])
        try await waitUntil { controller.status == .running }
        let answer = Task {
            await controller.requestPermission(
                for: .init(toolCallId: "t"),
                options: [.init(optionId: "ok", name: "OK", kind: .allowOnce)],
                in: agentID
            )
        }
        try await waitUntil { !controller.pendingPermissions.isEmpty }
        #expect(
            SessionConfigControls(session: controller).modeNote
                == "Changing the mode does not answer the waiting request."
        )
        let request = try #require(controller.pendingPermissions.first)
        controller.answerPermission(request.id, with: "ok")
        _ = await answer.value
        #expect(SessionConfigControls(session: controller).modeNote == nil)
        try await controller.stop()
        await fixture.remove()
    }

    // MARK: - Support

    /// A pending label long enough to push pills into `…`; once it is short again, applied or dropped, every pill is
    /// back in the row, in the same hosting view and at the same width.
    @Test(arguments: [true, false]) func pillsComeBackWhenAPendingLabelShrinks(applied: Bool) async throws {
        let choices = ACP.ConfigSelectOptions.flat([
            .init(value: "medium", name: "Medium"), .init(value: "high", name: "High"),
        ])
        func options(effort: String) -> [ACP.ConfigOption] {
            [
                .init(
                    id: "effort",
                    name: "Effort",
                    category: .thoughtLevel,
                    value: .select(currentValue: effort, options: choices)
                ),
                .init(id: "fast", name: "Fast mode", value: .boolean(currentValue: false)),
            ]
        }
        let state = RowState(options: options(effort: "medium"))
        _ = NSApplication.shared
        let host = NSHostingView(rootView: StateRow(state: state).frame(width: 180, alignment: .leading))
        let window = OffscreenWindow(size: .init(width: 700, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        }
        try await settle()
        #expect(popups(in: host).map { $0.accessibilityLabel() ?? "" } == ["Medium"])
        state.pending = ["effort": .select("high")]
        try await settle()
        #expect(popups(in: host).map { $0.accessibilityLabel() ?? "" }.last == "…")
        if applied { state.options = options(effort: "high") }
        state.pending = [:]
        try await settle()
        #expect(popups(in: host).map { $0.accessibilityLabel() ?? "" } == [applied ? "High" : "Medium"])
    }

    @MainActor @Observable final class RowState {
        var options: [ACP.ConfigOption]
        var pending: [ACP.ConfigOptionID: ACP.ConfigValue] = [:]
        init(options: [ACP.ConfigOption]) { self.options = options }
    }

    /// Updates one row in place, as a session's controls do.
    private struct StateRow: View {
        let state: RowState
        var body: some View { ConfigControlRow(options: state.options, pending: state.pending) { _, _ in } }
    }

    /// The titles of the row's menus, and whether they all lie inside it.
    private func labels(of view: some View, width: CGFloat) async throws -> (labels: [String], fits: Bool) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        let window = OffscreenWindow(size: .init(width: 700, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let menus = popups(in: host)
        let fits = menus.allSatisfy { $0.convert($0.bounds, to: host).maxX <= width + 0.5 }
        return (menus.map { $0.accessibilityLabel() ?? "" }, fits)
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popups)
    }

    /// A MockAgent session offering a mode, a model, an effort and `Fast mode`.
    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "config-row-\(UUID())")
        let sessions: SessionManager
        let model: SessionWindowModel
        let controller: SessionController

        init() async throws {
            sessions = SessionManager(library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite")))
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = SessionWindowModel(sessions: sessions)
            model.start(directory: directory, executable: binary.path, arguments: ["--effort", "--fast"])
            let owner = try #require(model.owner)
            await owner.startup?.value
            controller = try #require(owner.controller)
        }

        func remove() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
