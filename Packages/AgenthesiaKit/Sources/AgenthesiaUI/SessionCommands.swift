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
            Button("Review Changes", action: { model?.openReview() })
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(model?.canReview != true)
            Button(model?.mergeCommandTitle ?? "Merge…") { Task { [model] in await model?.requestMerge() } }
                .disabled(model?.canMerge != true)
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
            Button("Search Sessions") { model?.searchFocusRequests += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Previous Session") { Task { [model] in await model?.navigate(backward: true) } }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model?.navigationTarget(backward: true) == nil)
            Button("Next Session") { Task { [model] in await model?.navigate() } }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model?.navigationTarget() == nil)
            Button("Next Session Needing Input") { Task { [model] in await model?.navigate(needsInput: true) } }
                .keyboardShortcut("]", modifiers: [.command, .option, .shift])
                .disabled(model?.navigationTarget(needsInput: true) == nil)
        }
    }
}
