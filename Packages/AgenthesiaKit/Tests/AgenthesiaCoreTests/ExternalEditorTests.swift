import Foundation
import Testing

@testable import AgenthesiaCore

@Suite struct ExternalEditorTests {
    private let root = URL(filePath: "/Users/me/work tree")

    @Test func tableListsKnownEditorsByBundleIdentifier() {
        let identifiers = ExternalEditor.all.map(\.bundleIdentifier)
        #expect(
            identifiers == [
                "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
            ]
        )
        #expect(Set(identifiers).count == identifiers.count)
        #expect(ExternalEditor.named("dev.zed.Zed")?.name == "Zed")
        #expect(ExternalEditor.named("com.example.Nope") == nil)
    }

    @Test func vsCodeAndCursorOpenAtALine() throws {
        let vscode = try #require(ExternalEditor.named("com.microsoft.VSCode"))
        #expect(
            vscode.url(opening: "Sources/App.swift", line: 12, in: root)?.absoluteString
                == "vscode://file/Users/me/work%20tree/Sources/App.swift:12"
        )
        let cursor = try #require(ExternalEditor.named("com.todesktop.230313mzl4w4u92"))
        #expect(
            cursor.url(opening: "a.swift", line: 1, in: root)?.absoluteString
                == "cursor://file/Users/me/work%20tree/a.swift:1"
        )
    }

    @Test func omittedLineOpensTheFileWithoutOne() throws {
        let vscode = try #require(ExternalEditor.named("com.microsoft.VSCode"))
        #expect(
            vscode.url(opening: "a.swift", line: nil, in: root)?.absoluteString
                == "vscode://file/Users/me/work%20tree/a.swift"
        )
    }

    @Test func editorsWithoutALineTemplateHaveNoURL() throws {
        for identifier in ["dev.zed.Zed", "com.apple.dt.Xcode"] {
            let editor = try #require(ExternalEditor.named(identifier))
            #expect(editor.url(opening: "a.swift", line: 3, in: root) == nil)
        }
    }

    @Test func percentEncodesReservedAndNonASCIICharacters() throws {
        let vscode = try #require(ExternalEditor.named("com.microsoft.VSCode"))
        let url = try #require(vscode.url(opening: "dir #1/what?.swift/é 👩.swift", line: 9, in: root))
        #expect(
            url.absoluteString
                == "vscode://file/Users/me/work%20tree/dir%20%231/what%3F.swift/%C3%A9%20%F0%9F%91%A9.swift:9"
        )
        #expect(url.path(percentEncoded: false) == "/Users/me/work tree/dir #1/what?.swift/é 👩.swift:9")
        #expect(url.query == nil && url.fragment == nil)
    }
}
