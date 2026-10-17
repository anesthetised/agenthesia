import Foundation
import Testing

struct ProcessWaitTests {
    @Test func readsReadyChildPIDBeforeApplyingTheDeadline() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "child-pid-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try "12345\n".write(to: file, atomically: true, encoding: .utf8)

        // A delayed polling task can resume after its deadline even though the child is already ready.
        #expect(try await waitForChildPID(at: file, deadline: .now - .seconds(1)) == 12345)
    }

    @Test func missingChildPIDStillTimesOut() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "missing-child-pid-\(UUID()).txt")
        await #expect(throws: (any Error).self) {
            try await waitForChildPID(at: file, deadline: .now - .seconds(1))
        }
    }
}
