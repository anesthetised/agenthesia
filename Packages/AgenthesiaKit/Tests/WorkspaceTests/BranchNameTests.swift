import Foundation
import Testing

@testable import Workspace

@Suite(.timeLimit(.minutes(1))) struct BranchNameTests {
    let id = UUID(uuidString: "BAAEEDD5-1234-4321-ABCD-0123456789AB") ?? UUID()

    @Test(arguments: [
        ("Fix the note parser", "fix-the-note-parser"),
        ("  Fix: the NOTE parser!!  ", "fix-the-note-parser"),
        ("Исправь парсер заметок", "isprav-parser-zametok"),
        ("修复解析器", "xiu-fu-jie-xi-qi"),
        ("Café déjà vu — Straße", "cafe-deja-vu-strasse"),
        ("Add v2 API (#42)", "add-v2-api-42"),
        ("Refactor the session workspace removal check and its tests", "refactor-the-session-workspace-removal"),
        (String(repeating: "a", count: 50), String(repeating: "a", count: 40)),
        ("🚀🎉", "session"),
        ("", "session"),
    ])
    func namesTheBranchAfterTheTopic(topic: String, words: String) {
        #expect(SessionWorkspace.branchName(for: id, topic: topic) == "agenthesia/\(words)-baaeedd5")
    }

    @Test func aSessionWithoutATopicIsNamedSession() {
        #expect(SessionWorkspace.branchName(for: id, topic: nil) == "agenthesia/session-baaeedd5")
        #expect(SessionWorkspace.legacyBranchName(for: id) == "agenthesia/baaeedd5-1234-4321-abcd-0123456789ab")
    }

    @Test(arguments: [
        "..lock", "a..b", "x.lock", "@{u}", "-leading", "a/b//c", "end.", "tab\there", "~^:?*[\\", "😀 ü 中",
        String(repeating: "word ", count: 30),
    ])
    func everyNameIsAValidBranch(topic: String) async throws {
        let name = SessionWorkspace.branchName(for: UUID(), topic: topic)
        let words = name.dropFirst(SessionWorkspace.branchPrefix.count).dropLast(9)
        #expect(words.count <= SessionWorkspace.maxTopicLength)
        #expect(words.allSatisfy { $0 == "-" || ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        #expect(try await SessionWorkspace.git(["check-ref-format", "--branch", name], in: URL(filePath: "/")) == name)
    }

    @Test func onlyTheSessionsOwnNamesPassTheRemovalCheck() {
        let other = UUID()
        #expect(SessionWorkspace.isSessionBranch(SessionWorkspace.branchName(for: id, topic: "Fix"), of: id))
        #expect(SessionWorkspace.isSessionBranch(SessionWorkspace.legacyBranchName(for: id), of: id))
        for name in [
            SessionWorkspace.branchName(for: other, topic: "Fix"), SessionWorkspace.legacyBranchName(for: other),
            "feature/fix-baaeedd5", "fix-baaeedd5", "agenthesia/fix", "agenthesia/fixbaaeedd5", "main", "",
        ] {
            #expect(!SessionWorkspace.isSessionBranch(name, of: id), "\(name)")
        }
    }
}
