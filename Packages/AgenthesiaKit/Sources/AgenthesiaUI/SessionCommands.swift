import AgenthesiaCore
public import SwiftUI

extension FocusedValues {
    @Entry var sessionWindow: SessionWindowModel?
}

/// Session actions follow the key window's selection, even when its composer has focus.
public struct SessionCommands: Commands {
    @FocusedValue(\.sessionWindow) private var model

    public init() {}

    public var body: some Commands {
        // Read in the body, so the menu follows the sidebar.
        let sessions = model?.numberedSessions ?? Array(repeating: nil, count: SessionSidebar.numberedCount)
        CommandMenu("Session") {
            Button("New Session") { model?.showingSetup = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.canStart != true)
            Button(model?.owner?.isStarting == true ? "Cancel Startup" : "End Session") {
                Task { [model] in await model?.endSession() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model?.canEnd != true)
            Button(model?.archiveCommandTitle ?? "Archive Session") {
                Task { [model] in await model?.toggleArchived() }
            }
            .disabled(model?.canArchive != true)
            .help(model?.archiveHelp ?? "")
            Button("Delete Session…") {
                Task { [model] in
                    guard let session = model?.displayed?.session else { return }
                    await model?.requestDelete(session)
                }
            }
            .disabled(model?.canDelete != true)
            .help(model?.archiveHelp ?? "")
            Button("Discard Worktree…") {
                Task { [model] in
                    guard let session = model?.displayed?.session else { return }
                    await model?.requestDiscard(session)
                }
            }
            .disabled(model?.canDiscard != true)
            .help(model?.discardHelp ?? "")
            Button(model?.isReviewShown == true ? "Hide Review" : "Review Changes") { model?.toggleReview() }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(model?.canReview != true)
            Button("Mark Viewed and Go to Next") { model?.markViewedAndAdvance() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model?.canMarkViewed != true)
            Button("Ask Agent") { model?.askAgent() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model?.canAskAgent != true)
                .help(model?.askAgentHelp ?? "")
            if model?.showsMerge != false {
                Button(model?.mergeCommandTitle ?? "Merge…") { Task { [model] in await model?.requestMerge() } }
                    .disabled(model?.canMerge != true)
                    .help(model?.mergeHelp ?? "")
            }
            if model?.showsOpenPullRequest == true {
                Button("Open Pull Request…") { model?.requestPullRequest() }
                    .disabled(model?.canOpenPullRequest != true)
            }
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
            Button("Focus Composer") { model?.focusComposer() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model?.canFocusComposer != true)
            Button("Search Sessions") { model?.searchFocusRequests += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Find in Transcript") { model?.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model?.canFind != true)
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model?.find.isOpen != true || model?.find.query.isEmpty != false)
            Button("Find Previous") { model?.findNext(backward: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model?.find.isOpen != true || model?.find.query.isEmpty != false)
            Button("Next Failed Tool Call") { model?.nextFailedToolCall() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model?.canFind != true)
            Button("Jump to Latest") { model?.jumpToLatest() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model?.canJumpToLatest != true)
            Divider()
            Menu("Switch to Session") {
                ForEach(Array(sessions.enumerated()), id: \.offset) { index, row in
                    Button(row?.title ?? "No Session") {
                        if let row { model?.switchToSession(row) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(row == nil)
                }
            }
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
