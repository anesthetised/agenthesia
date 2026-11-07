import ACP
import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

/// The labels of an accessibility tree, outermost first.
@MainActor func accessibilityLabels(in element: Any) -> [String] {
    guard let element = element as? any NSAccessibilityProtocol else { return [] }
    let own = element.accessibilityLabel().map { [$0] } ?? []
    return own + (element.accessibilityChildren() ?? []).flatMap { accessibilityLabels(in: $0) }
}

@MainActor private func accessibilityElement(labeled label: String, in element: Any) -> (any NSAccessibilityProtocol)? {
    guard let element = element as? any NSAccessibilityProtocol else { return nil }
    if element.accessibilityLabel() == label { return element }
    return (element.accessibilityChildren() ?? []).lazy.compactMap { accessibilityElement(labeled: label, in: $0) }
        .first
}

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

    @Test func thePopoverListsEveryModeWithItsDescription() async throws {
        let (host, window) = hosted(ModeChoices(choices: choices, selected: "code") { _ in })
        defer { window.close() }
        try await settle(host)
        let labels = accessibilityLabels(in: host)
        for expected in ["Ask. Asks before every change", "Code. Edits files directly", "Plain"] {
            #expect(labels.contains(expected))
        }
    }

    @Test func groupsKeepTheirHeaders() async throws {
        let grouped = ACP.ConfigSelectOptions.grouped([
            .init(group: "safe", name: "Careful", options: [.init(value: "ask", name: "Ask")]),
            .init(group: "free", name: "Unattended", options: [.init(value: "code", name: "Code")]),
        ])
        let (host, window) = hosted(ModeChoices(choices: grouped, selected: nil) { _ in })
        defer { window.close() }
        try await settle(host)
        let labels = accessibilityLabels(in: host)
        #expect(labels.contains("Careful") && labels.contains("Unattended") && labels.contains("Code"))
    }

    @Test func choosingARowCallsOnSelect() async throws {
        var chosen: [ACP.ConfigValueID] = []
        let (host, window) = hosted(ModeChoices(choices: choices, selected: "code") { chosen.append($0) })
        defer { window.close() }
        try await settle(host)
        let row = try #require(accessibilityElement(labeled: "Ask. Asks before every change", in: host))
        #expect(row.accessibilityPerformPress())
        #expect(chosen == ["ask"])
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
        #expect(accessibilityLabels(in: modeHost).contains("x: Code"))
        #expect(popups(in: modeHost).isEmpty)

        let model = ConfigSelectMenu(option: option(.model), choices: choices, selected: "code") { _ in }
        let (modelHost, modelWindow) = hosted(model)
        defer { modelWindow.close() }
        try await settle(modelHost)
        #expect(popups(in: modelHost).count == 1)
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popups)
    }
}
