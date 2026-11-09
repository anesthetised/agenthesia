public import AgenthesiaCore
import AppKit
public import SwiftUI

/// The menu bar item's icon, with the number of sessions in Needs You beside it while there are any.
public struct SessionMenuBarLabel: View {
    private let sessions: SessionManager

    public init(sessions: SessionManager) { self.sessions = sessions }

    public var body: some View {
        let count = SessionMenu(owners: sessions.owners).needsYou.count
        HStack {
            Image(systemName: "sparkles")
            if count > 0 { Text(count, format: .number) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "Agenthesia, \(count) need you" : "Agenthesia")
    }
}

/// The menu bar item's menu: Needs You, Working, New Session, and Open Agenthesia when no window is open (ADR-0046).
/// A session opens through its `WindowTarget` URL, as a notification does (ADR-0030).
public struct SessionMenuBarContent: View {
    private let sessions: SessionManager
    private let open: (URL) -> Void
    @State private var windows = WindowPresence()
    @Environment(\.openWindow) private var openWindow

    public init(sessions: SessionManager, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.sessions = sessions
        self.open = open
    }

    public var body: some View {
        let menu = SessionMenu(owners: sessions.owners)
        if !menu.needsYou.isEmpty {
            Section("Needs You") { ForEach(menu.needsYou) { entry($0) } }
        }
        if !menu.working.isEmpty {
            Section("Working") { ForEach(menu.working) { entry($0) } }
        }
        Divider()
        Button("New Session", action: showWindow)
        if !windows.isOpen { Button("Open Agenthesia", action: showWindow) }
    }

    /// An item opens its session. A pending permission turns it into a submenu of the agent's options; Open leads it, as the item opens the
    /// session otherwise.
    @ViewBuilder private func entry(_ entry: SessionMenu.Entry) -> some View {
        if let request = entry.request {
            Menu(entry.text) {
                ForEach(PermissionChoice.choices(for: request, openAlways: true)) { choice in
                    switch choice {
                    case .open: Button("Open") { show(entry) }.disabled(entry.url == nil)
                    case .option(let option): Button(option.name) { entry.answer(option.optionId) }
                    }
                }
            }
        } else {
            Button(entry.text) { show(entry) }.disabled(entry.url == nil)
        }
    }

    private func show(_ entry: SessionMenu.Entry) {
        if let url = entry.url { open(url) }
    }

    private func showWindow() {
        openWindow(value: WindowTarget.launch)
        NSApp.activate()
    }
}
