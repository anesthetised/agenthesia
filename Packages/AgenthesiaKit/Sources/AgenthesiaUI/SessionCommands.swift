public import SwiftUI

extension FocusedValues {
    @Entry var sessionWindow: SessionWindowModel?
}

/// Session actions follow the key window's selection, even when its composer has focus.
public struct SessionCommands: Commands {
    @FocusedValue(\.sessionWindow) private var model

    public init() {}

    public var body: some Commands {
        CommandMenu("Session") {
            Button("New Session") { model?.showingSetup = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.canStart != true)
            Button(model?.owner?.isStarting == true ? "Cancel Startup" : "End Session") {
                Task { [model] in await model?.endSession() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model?.canEnd != true)
            Button("Discard Worktree…") {
                Task { [model] in
                    guard let session = model?.displayed?.session else { return }
                    await model?.requestDiscard(session)
                }
            }
            .disabled(model?.canDiscard != true)
            Divider()
            Button("Stop") { Task { [model] in await model?.stop() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model?.canStop != true)
            Button("Continue") { model?.continueRestored() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.canContinue != true)
            Button("Resume Queue") { Task { [model] in await model?.resumeQueue() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.canResumeQueue != true)
            Divider()
            Button("Previous Session") { Task { [model] in await model?.navigate(backward: true) } }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model?.navigationTarget(backward: true) == nil)
            Button("Next Session") { Task { [model] in await model?.navigate() } }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model?.navigationTarget() == nil)
            Button("Next Session Needing Input") { Task { [model] in await model?.navigate(needsInput: true) } }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model?.navigationTarget(needsInput: true) == nil)
        }
    }
}
