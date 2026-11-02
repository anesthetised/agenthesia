import SwiftUI

/// Find in the transcript (⌘F): Return steps to the next match, Escape closes.
struct TranscriptFindBar: View {
    @Bindable var model: SessionWindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find in Transcript", text: $model.find.query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.findNext() }
                .onExitCommand { model.closeFind() }
            Text(model.find.status)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize()
            Button("Previous Match", systemImage: "chevron.up") { model.findNext(backward: true) }
                .disabled(model.find.matches.isEmpty)
                .help("Previous match (⇧⌘G)")
            Button("Next Match", systemImage: "chevron.down") { model.findNext() }
                .disabled(model.find.matches.isEmpty)
                .help("Next match (⌘G)")
            Button("Close Find", systemImage: "xmark") { model.closeFind() }
                .help("Close (Esc)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
        .padding(8)
        .onAppear { focused = true }
        .onChange(of: model.find.focusRequests) { focused = true }
        .onChange(of: model.find.status) {
            if !model.find.status.isEmpty { AccessibilityNotification.Announcement(model.find.status).post() }
        }
        .task(id: model.find.query) {
            // Reading every item's full text on each keystroke would make typing lag on a long session.
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { model.updateFindMatches() }
        }
    }
}
