import ACP
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore

struct PermissionChoiceTests {
    private let allow = ACP.PermissionOption(optionId: "allow", name: "Allow once", kind: .allowOnce)
    private let always = ACP.PermissionOption(optionId: "always", name: "Always allow", kind: .allowAlways)
    private let reject = ACP.PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)

    private func request(_ call: ACP.ToolCall) -> SessionController.PendingPermission {
        .init(
            id: UUID(),
            options: [allow, always, reject],
            toolTitle: call.title,
            callTitle: call.title,
            toolCall: call
        )
    }

    @Test func aRequestWithADiffOffersOpenFirstThenTheOptionsInTheAgentsOrder() {
        let edit = ACP.ToolCall(
            toolCallId: "edit",
            title: "Update the notes",
            kind: .edit,
            content: [
                .content(.init(content: .init(text: "Context"))),
                .diff(.init(path: "a.txt", oldText: "old", newText: "new")),
            ]
        )
        #expect(
            PermissionChoice.choices(for: request(edit)) == [.open, .option(allow), .option(always), .option(reject)]
        )
    }

    @Test func aRequestWithoutADiffCanBeAnsweredInPlace() {
        let command = ACP.ToolCall(toolCallId: "run", title: "swift test", kind: .execute)
        #expect(PermissionChoice.choices(for: request(command)) == [.option(allow), .option(always), .option(reject)])
        let described = ACP.ToolCall(
            toolCallId: "fetch",
            title: "Fetch",
            kind: .fetch,
            content: [.content(.init(content: .init(text: "https://example.com")))]
        )
        #expect(PermissionChoice.choices(for: request(described)).first == .option(allow))
    }

    @Test func aCommandTheBoardCutsOffersOpenFirst() {
        let long = ACP.ToolCall(
            toolCallId: "run",
            title: "Bash",
            kind: .execute,
            rawInput: ["command": .string(String(repeating: "echo\n", count: 5))]
        )
        #expect(PermissionChoice.choices(for: request(long)).first == .open)
        let short = ACP.ToolCall(toolCallId: "run", title: "Bash", kind: .execute, rawInput: ["command": "echo"])
        #expect(PermissionChoice.choices(for: request(short)).first == .option(allow))
    }

    @Test func aSurfaceWithNoOtherWayToOpenAsksForOpenEvenWithoutADiff() {
        let command = ACP.ToolCall(toolCallId: "run", title: "swift test", kind: .execute)
        #expect(
            PermissionChoice.choices(for: request(command), openAlways: true)
                == [.open, .option(allow), .option(always), .option(reject)]
        )
        // A diff does not add a second Open.
        let edit = ACP.ToolCall(
            toolCallId: "edit",
            title: "Edit",
            content: [.diff(.init(path: "a.txt", oldText: nil, newText: "x"))]
        )
        #expect(PermissionChoice.choices(for: request(edit), openAlways: true).filter { $0 == .open }.count == 1)
    }

    @Test func choicesHaveDistinctIdentities() {
        let command = ACP.ToolCall(toolCallId: "run", title: "swift test")
        let ids = PermissionChoice.choices(for: request(command), openAlways: true).map(\.id)
        #expect(Set(ids).count == ids.count && ids.first == "open")
    }

    @Test func aRequestWithoutOptionsOffersOnlyOpenWhereOpenIsAsked() {
        let call = ACP.ToolCall(toolCallId: "run", title: "swift test")
        let bare = SessionController.PendingPermission(
            id: UUID(),
            options: [],
            toolTitle: nil,
            callTitle: nil,
            toolCall: call
        )
        #expect(PermissionChoice.choices(for: bare).isEmpty)
        #expect(PermissionChoice.choices(for: bare, openAlways: true) == [.open])
    }
}
