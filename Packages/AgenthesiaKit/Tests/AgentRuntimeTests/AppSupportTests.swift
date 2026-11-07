import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct AppSupportTests {
    @Test func originalIdentifierKeepsTheOriginalFolder() {
        #expect(AppSupport.folderName(bundleIdentifier: "io.github.anesthetised.Agenthesia") == "Agenthesia")
    }

    @Test func missingOrUnrelatedIdentifierKeepsTheOriginalFolder() {
        #expect(AppSupport.folderName(bundleIdentifier: nil) == "Agenthesia")
        #expect(AppSupport.folderName(bundleIdentifier: "com.apple.dt.xctest.tool") == "Agenthesia")
        #expect(AppSupport.folderName(bundleIdentifier: "io.github.anesthetised.Agenthesia.") == "Agenthesia")
    }

    @Test func suffixedIdentifierGetsItsOwnFolder() {
        #expect(AppSupport.folderName(bundleIdentifier: "io.github.anesthetised.Agenthesia.dev") == "Agenthesia-dev")
        #expect(
            AppSupport.folderName(bundleIdentifier: "io.github.anesthetised.Agenthesia.tabtest")
                == "Agenthesia-tabtest"
        )
    }

    @Test func directoryIsInsideApplicationSupport() {
        #expect(AppSupport.directory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
