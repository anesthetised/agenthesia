import ACP
import AgenthesiaCore
import Rendering
import SwiftUI

/// The oldest pending permission request, as the card above the composer shows it (ADR-0039, amendment 2026-11-02).
struct DockedPermission: Equatable {
    let request: SessionController.PendingPermission
    /// How many requests are pending, this one included.
    let count: Int

    /// The oldest of `pending`, which is the one the card and ⌥⌘1… answer.
    init?(_ pending: [SessionController.PendingPermission]) {
        guard let oldest = pending.first else { return nil }
        request = oldest
        count = pending.count
    }

    var id: UUID { request.id }
    var options: [ACP.PermissionOption] { request.options }
    /// `1 of 3` while several requests are pending; there is no navigation between them.
    var counter: String? { count > 1 ? "1 of \(count)" : nil }
    var symbol: String { LiveTranscriptSource.kind(request.toolCall.kind).symbol }

    /// The kind, then the paths the call names: its locations, then the files its diffs edit.
    var operation: String {
        let tool = request.toolCall
        var paths: [String] = []
        for path in (tool.locations ?? []).map(\.path) + diffs.map(\.path) where !paths.contains(path) {
            paths.append(path)
        }
        let kind = LiveTranscriptSource.kind(tool.kind).label
        return paths.isEmpty ? kind : "\(kind) · \(paths.joined(separator: ", "))"
    }

    /// Agent-authored text, shown after the operation as secondary text.
    var title: String? { request.toolCall.title.isEmpty ? nil : request.toolCall.title }

    var diffs: [ACP.Diff] {
        (request.toolCall.content ?? []).compactMap { if case .diff(let diff) = $0 { diff } else { nil } }
    }

    var announcement: String {
        "Permission request: \(operation)" + (count > 1 ? ", \(count) pending" : "")
    }

    /// ⌥⌘1…⌥⌘9 for the first nine options.
    static func shortcut(at index: Int) -> (key: KeyboardShortcut, label: String)? {
        guard (0..<9).contains(index) else { return nil }
        return (
            KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option]), "⌥⌘\(index + 1)"
        )
    }

    /// Answers this request with its option at `index`, from a click or ⌥⌘`index + 1`, once `arming` allows it.
    @MainActor @discardableResult
    func answer(
        option index: Int,
        in session: SessionController,
        arming: PermissionArming,
        at now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard arming.accepts(at: now), options.indices.contains(index) else { return false }
        return session.answerPermission(id, with: options[index].optionId)
    }
}

/// Buttons and shortcuts ignore input for `delay` after a request appears on the card, so a double click or a held
/// ⌥⌘1 meant for one request does not also answer the next, which appears under the same pointer (ADR-0039).
struct PermissionArming: Equatable {
    static let delay = Duration.milliseconds(400)
    let shownAt: ContinuousClock.Instant

    var armedAt: ContinuousClock.Instant { shownAt.advanced(by: Self.delay) }
    func accepts(at now: ContinuousClock.Instant) -> Bool { now >= armedAt }
}

/// The oldest pending permission request, docked between the status line and the composer card, so it stays on
/// screen whatever the transcript's scroll position (ADR-0039, amendment 2026-11-02). It never takes focus, and
/// only a click or ⌥⌘1… answers it; Return and Escape stay with the composer.
struct PermissionDock: View {
    let session: SessionController
    /// 40 % of the transcript column; the diff scrolls inside the card beyond it.
    let maxHeight: CGFloat

    var body: some View {
        if let docked = DockedPermission(session.pendingPermissions) {
            // A new identity per request restarts arming and collapses the extra files.
            PermissionCard(docked: docked, session: session, maxHeight: maxHeight).id(docked.id)
        }
    }
}

private struct PermissionCard: View {
    let docked: DockedPermission
    let session: SessionController
    let maxHeight: CGFloat
    @State private var arming = PermissionArming(shownAt: .now)
    /// Only how the buttons look; `arming` decides whether an answer counts.
    @State private var armed = false
    @State private var showsAllFiles = false
    @State private var diffHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(docked.operation, systemImage: docked.symbol).fontWeight(.semibold)
                Spacer(minLength: 8)
                if let counter = docked.counter {
                    Text(counter).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let title = docked.title {
                Text(title).foregroundStyle(.secondary)
            }
            if let first = docked.diffs.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PermissionDiff(diff: first)
                        if showsAllFiles {
                            ForEach(docked.diffs.dropFirst(), id: \.self) { PermissionDiff(diff: $0) }
                        } else if docked.diffs.count > 1 {
                            let more = docked.diffs.count - 1
                            Button("+\(more) more file\(more == 1 ? "" : "s")") { showsAllFiles = true }
                                .buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        diffHeight = $0
                    }
                }
                .frame(maxHeight: diffHeight)
            }
            WrappingLayout(spacing: 8) {
                ForEach(docked.options.enumerated(), id: \.offset) { index, option in
                    optionButton(option, at: index)
                }
            }
            .disabled(!armed)
        }
        .padding(12)
        .frame(maxHeight: maxHeight)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request")
        .onAppear { AccessibilityNotification.Announcement(docked.announcement).post() }
        .task {
            try? await Task.sleep(until: arming.armedAt, clock: .continuous)
            armed = !Task.isCancelled
        }
    }

    private func optionButton(_ option: ACP.PermissionOption, at index: Int) -> some View {
        let shortcut = DockedPermission.shortcut(at: index)
        let remembered = option.kind == .allowAlways || option.kind == .rejectAlways
        return Button {
            answer(index)
        } label: {
            HStack(spacing: 4) {
                Text(option.name)
                if let shortcut {
                    Text(shortcut.label).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
        .keyboardShortcut(shortcut?.key)
        .help(remembered ? "“Always” is remembered by the agent, not by Agenthesia." : "")
    }

    private func answer(_ index: Int) {
        docked.answer(option: index, in: session, arming: arming)
    }
}

/// One edit as a unified diff with its path.
private struct PermissionDiff: View {
    let diff: ACP.Diff

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(diff.path + (diff.oldText == nil ? " (new file)" : "")).font(.caption).foregroundStyle(.secondary)
            Text(Self.lines(diff)).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    static func lines(_ diff: ACP.Diff) -> AttributedString {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: diff.oldText, new: diff.newText))
        guard !lines.isEmpty else { return AttributedString("No changes") }
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            let (mark, color): (String, Color?) =
                switch line.kind {
                case .hunk: ("", .secondary)
                case .added: ("+", .green)
                case .removed: ("-", .red)
                case .context: (" ", nil)
                }
            var part = AttributedString((index == 0 ? "" : "\n") + mark + line.text)
            part.foregroundColor = color
            text += part
        }
        return text
    }
}

/// Subviews left to right at their ideal size, starting a new row where the next one does not fit. None is
/// narrowed, so button titles never truncate.
struct WrappingLayout: Layout {
    var spacing: CGFloat

    /// Each subview's origin and the size of them all, for subviews of `sizes` in a row `width` wide.
    static func origins(of sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.origins(of: sizes, width: proposal.width ?? .infinity, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let origins = Self.origins(of: sizes, width: bounds.width, spacing: spacing).origins
        for (subview, (origin, size)) in zip(subviews, zip(origins, sizes)) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(size)
            )
        }
    }
}
