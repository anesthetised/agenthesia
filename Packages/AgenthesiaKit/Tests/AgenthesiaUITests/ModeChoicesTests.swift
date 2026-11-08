import ACP
import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct ModeChoicesTests {
    private let choices = ACP.ConfigSelectOptions.flat([
        .init(value: "ask", name: "Ask", description: "Asks before every change"),
        .init(value: "code", name: "Code", description: "Edits files directly"),
        .init(value: "plain", name: "Plain"),
    ])

    private func hosted(_ view: some View) -> (NSHostingView<AnyView>, OffscreenWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view))
        let window = OffscreenWindow(size: .init(width: 400, height: 500))
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<30 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    }

    @Test func aRowLabelHasTheNameAndTheDescription() {
        #expect(ModeChoices.label(of: choices.allOptions[0]) == "Ask. Asks before every change")
        #expect(ModeChoices.label(of: choices.allOptions[2]) == "Plain")
    }

    @Test func theModePillIsAButtonWithTheModesNameAndOtherSelectsStayMenus() async throws {
        func option(_ category: ACP.ConfigOptionCategory) -> ACP.ConfigOption {
            .init(id: "x", name: "x", category: category, value: .select(currentValue: "code", options: choices))
        }
        let mode = ConfigSelectMenu(option: option(.mode), choices: choices, selected: "code") { _ in }
        #expect(mode.accessibilityText == "x: Code")
        let (modeHost, modeWindow) = hosted(mode)
        defer { modeWindow.close() }
        try await settle(modeHost)
        #expect(popups(in: modeHost).isEmpty)

        let model = ConfigSelectMenu(option: option(.model), choices: choices, selected: "code") { _ in }
        let (modelHost, modelWindow) = hosted(model)
        defer { modelWindow.close() }
        try await settle(modelHost)
        #expect(popups(in: modelHost).count == 1)
    }

    private func table(in view: NSView) -> NSTableView? {
        (view as? NSTableView) ?? view.subviews.lazy.compactMap(table).first
    }

    /// How far the list's height is from its rows' extent plus the list's padding.
    private func slack(_ choices: ACP.ConfigSelectOptions) async throws -> CGFloat {
        let (host, window) = hosted(ModeChoices(choices: choices, selected: nil) { _ in })
        defer { window.close() }
        try await settle(host)
        let list = try #require(table(in: host))
        let content = list.rect(ofRow: list.numberOfRows - 1).maxY + ModeChoices.verticalPadding / 2
        return ModeChoices.height(of: choices) - content
    }

    @Test func twoShortRowsLeaveNoGapUnderThem() async throws {
        let two = ACP.ConfigSelectOptions.flat(Array(choices.allOptions.prefix(2)))
        #expect(ModeChoices.height(of: two) == 2 * ModeChoices.describedRowHeight + ModeChoices.verticalPadding)
        #expect(abs(try await slack(two)) <= 1)
        #expect(abs(try await slack(choices)) <= 1)
    }

    @Test func groupedChoicesAddAHeaderPerGroupAndALongListIsCapped() async throws {
        let grouped = ACP.ConfigSelectOptions.grouped([
            .init(group: "a", name: "A", options: Array(choices.allOptions.prefix(2))),
            .init(group: "b", name: "B", options: [choices.allOptions[2]]),
        ])
        #expect(
            ModeChoices.height(of: grouped)
                == 2 * ModeChoices.describedRowHeight + ModeChoices.plainRowHeight
                + 2 * ModeChoices.sectionHeaderHeight + ModeChoices.verticalPadding
        )
        #expect(abs(try await slack(grouped)) <= 1)

        let many = ACP.ConfigSelectOptions.flat((0..<30).map { .init(value: .init("m\($0)"), name: "Mode \($0)") })
        #expect(ModeChoices.height(of: many) == ModeChoices.maxHeight)
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popups)
    }
}
