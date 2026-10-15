import ACP
import AgenthesiaCore
import SwiftUI

/// Pending messages remain separate from the transcript until their atomic grouped send.
struct PromptQueue: View {
    let session: SessionController
    let editable: Bool
    let onEdit: (QueuedPrompt) -> Void
    let onError: (any Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.queuePaused ? "Queue paused" : "Queued messages").font(.caption).foregroundStyle(
                    .secondary
                )
                Spacer()
                if session.queuePaused, editable {
                    Button("Resume Queue", systemImage: "play.fill", action: resume)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help("Resume queued messages (⇧⌘R)")
                        .disabled(session.status == .stopping)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.queuedPrompts.enumerated(), id: \.element.id) { index, prompt in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(prompt.text.isEmpty ? "Attachments" : prompt.text).lineLimit(2)
                                ForEach(Array(prompt.content.enumerated()), id: \.offset) { _, block in
                                    if case .resourceLink(let link) = block {
                                        Label(link.name, systemImage: "paperclip").font(.caption).foregroundStyle(
                                            .secondary
                                        )
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            if editable {
                                Button("Edit queued message", systemImage: "pencil") { onEdit(prompt) }
                                Button("Move queued message up", systemImage: "arrow.up") {
                                    move(prompt.id, to: index - 1)
                                }
                                .disabled(index == 0)
                                Button("Move queued message down", systemImage: "arrow.down") {
                                    move(prompt.id, to: index + 1)
                                }
                                .disabled(index == session.queuedPrompts.count - 1)
                                Button("Delete queued message", systemImage: "trash") { remove(prompt.id) }
                            }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).padding(8)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                    }
                }
            }.frame(maxHeight: 180)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Prompt queue")
    }

    private func resume() { Task { do { try await session.resumeQueue() } catch { onError(error) } } }
    private func move(_ id: UUID, to index: Int) {
        Task { do { try await session.moveQueuedPrompt(id, to: index) } catch { onError(error) } }
    }
    private func remove(_ id: UUID) {
        Task { do { try await session.removeQueuedPrompt(id) } catch { onError(error) } }
    }
}
