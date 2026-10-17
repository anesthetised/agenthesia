import AgenthesiaCore
import Foundation
import Testing

@testable import AgenthesiaUI

@MainActor
@Suite struct EditorHandoffTests {
    private let root = URL(filePath: "/work/tree")
    private let app = URL(filePath: "/Applications/Editor.app")

    @Test func lineCapableEditorsGetTheirURL() throws {
        let vscode = try #require(ExternalEditor.named("com.microsoft.VSCode"))
        let action = EditorHandoff.action(path: "a b.swift", line: 4, root: root, editor: vscode, appURL: app)
        #expect(action == .url(try #require(URL(string: "vscode://file/work/tree/a%20b.swift:4"))))
    }

    @Test func editorsWithoutALineOrWithoutOneRequestedOpenTheFile() throws {
        let zed = try #require(ExternalEditor.named("dev.zed.Zed"))
        let file = root.appending(path: "a.swift")
        #expect(
            EditorHandoff.action(path: "a.swift", line: 4, root: root, editor: zed, appURL: app)
                == .file(file, app: app)
        )
        let vscode = try #require(ExternalEditor.named("com.microsoft.VSCode"))
        #expect(
            EditorHandoff.action(path: "a.swift", line: nil, root: root, editor: vscode, appURL: app)
                == .file(file, app: app)
        )
    }

    @Test func missingChoiceOrMissingAppFallsBackToTheSystemDefault() throws {
        let file = root.appending(path: "a.swift")
        let zed = try #require(ExternalEditor.named("dev.zed.Zed"))
        #expect(
            EditorHandoff.action(path: "a.swift", line: 2, root: root, editor: nil, appURL: nil) == .systemDefault(file)
        )
        #expect(
            EditorHandoff.action(path: "a.swift", line: 2, root: root, editor: zed, appURL: nil) == .systemDefault(file)
        )
        #expect(
            EditorHandoff.action(path: "a.swift", line: 2, root: root, editor: nil, appURL: app) == .systemDefault(file)
        )
    }
}
