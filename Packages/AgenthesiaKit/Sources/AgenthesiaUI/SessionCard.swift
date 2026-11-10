import ACP
import AgenthesiaCore
import SwiftUI

/// One live session on the board: what its sidebar row says, the agent's last line and, while a permission request
/// waits, its operation and the agent's options. Clicking the card selects the session.
struct SessionCard: View {
    /// What a card shows, read from the session on every render like the sidebar row.
    @MainActor struct Content: Identifiable {
        let row: SessionSidebar.Row
        let title: String
        let project: String?
        let isScratch: Bool
        let reason: String?
        let activity: LiveSession.Activity
        let lastLine: String?
        let lastActivity: Date?
        let turnStartedAt: Date?
        /// The oldest pending permission request and the session that answers it.
        let request: SessionController.PendingPermission?
        let session: SessionController?

        var id: AnyHashable { row.id }

        init(owner: LiveSession, row: SessionSidebar.Row, model: SessionWindowModel) {
            self.row = row
            title = row.title
            project = row.project?.name
            isScratch = model.isScratch(row.project)
            reason = model.reason(of: owner)
            activity = owner.activity
            lastLine = owner.controller?.transcript.agentLastLine
            lastActivity = row.lastActivity
            turnStartedAt = owner.controller?.turnStartedAt
            session = owner.controller
            request = session?.pendingPermissions.first
        }

        /// The plain rule (ADR-0046): Open leads only for a request with a diff or a command the card cuts; the card
        /// itself opens the session.
        var choices: [PermissionChoice] { request.map { PermissionChoice.choices(for: $0) } ?? [] }

        /// The running turn's `Working 1m 12s`, or an idle session's `Idle 20m`, as on the Working shelf
        /// (`SessionSidebar.shelfTime`); else the time of the last activity, as on a Needs You row.
        func time(now: Date = .now) -> String? {
            SessionSidebar.shelfTime(
                activity: activity,
                turnStartedAt: turnStartedAt,
                lastActivity: lastActivity,
                now: now
            ) ?? lastActivity.map { RelativeTime.short(from: $0, to: now) }
        }

        /// The row's label, then the agent's last line.
        func accessibilityLabel(now: Date = .now) -> String {
            let shelf = SessionSidebar.shelfTime(
                activity: activity,
                turnStartedAt: turnStartedAt,
                lastActivity: lastActivity,
                now: now
            )
            let label = SessionRow.accessibilityLabel(
                title: title,
                project: project,
                reason: reason,
                status: activity,
                lastActivity: shelf == nil ? lastActivity : nil,
                shelfTime: shelf,
                now: now
            )
            return [label, lastLine].compactMap(\.self).joined(separator: ", ")
        }
    }

    let content: Content
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A running turn counts seconds, as its shelf row does; otherwise the time changes by the minute.
            if let turnStartedAt = content.turnStartedAt {
                TimelineView(.periodic(from: turnStartedAt, by: 1)) { summary(now: $0.date) }
            } else {
                TimelineView(.everyMinute) { summary(now: $0.date) }
            }
            if let request = content.request, let session = content.session {
                // A new identity per request, or per command, restarts arming.
                BoardPermission(request: request, session: session, choices: content.choices, open: open)
                    .id(DockedPermission([request])?.identity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
    }

    /// The card's button: one accessibility element with the row's label and the last line, a stop of Tab.
    private func summary(now: Date) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProjectBadgeView(name: content.project, isScratch: content.isScratch)
                    Text(content.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    StatusIcon(activity: content.activity)
                    if let time = content.time(now: now) {
                        Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if content.project != nil || content.reason != nil {
                    SubtitleLayout {
                        if let project = content.project { Text(project).lineLimit(1) }
                        if let reason = content.reason {
                            Text(content.project == nil ? reason : " · \(reason)").lineLimit(1)
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                if let line = content.lastLine {
                    Text(line).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // In the key view loop also without keyboard navigation, so Tab reaches every card (ADR-0046).
        .focusable()
        .onKeyPress(keys: [.space, .return]) { _ in
            open()
            return .handled
        }
        .accessibilityLabel(content.accessibilityLabel(now: now))
    }
}

/// A pending permission on a card: the operation line, a command in up to four lines and the agent's options, without
/// the diff or shortcuts (ADR-0046). Like the docked card, the buttons arm 400 ms after the request appears, since cards move when a session
/// changes section.
private struct BoardPermission: View {
    let request: SessionController.PendingPermission
    let session: SessionController
    let choices: [PermissionChoice]
    let open: () -> Void
    @State private var arming = PermissionArming(shownAt: .now)
    /// Only how the buttons look; `arming` decides whether an answer counts.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let docked = DockedPermission([request]) {
                Label(docked.operation, systemImage: docked.symbol).fontWeight(.semibold).lineLimit(2)
                if let command = docked.command {
                    Text(command).font(.caption.monospaced()).lineLimit(PermissionCommand.boardLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            WrappingLayout(spacing: 8) {
                ForEach(choices) { choice in
                    switch choice {
                    case .open: Button("Open", action: open).buttonStyle(.borderedProminent)
                    case .option(let option):
                        Button(option.name) { answer(option) }
                    }
                }
            }
            .disabled(!armed)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request")
        .task {
            try? await Task.sleep(until: arming.armedAt, clock: .continuous)
            armed = !Task.isCancelled
        }
    }

    private func answer(_ option: ACP.PermissionOption) {
        guard arming.accepts(at: .now) else { return }
        session.answerPermission(request.id, with: option.optionId)
    }
}
