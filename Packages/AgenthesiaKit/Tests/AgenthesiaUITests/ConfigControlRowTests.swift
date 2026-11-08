import ACP
import AppKit
import Foundation
import Persistence
import SwiftUI
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
        var errors: [String?] = []
        SessionConfigControls(session: controller) { errors.append($0) }.change("fast", to: .boolean(true))
        #expect(fast() == .boolean(currentValue: false))
        try await waitUntil { fast() == .boolean(currentValue: true) && !controller.isChangingConfig }
        #expect(errors == [nil])
        await fixture.remove()
    }

    // MARK: - Support

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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
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
