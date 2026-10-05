import Testing

@testable import Workspace

@Test func moduleLoads() {
    #expect(String(describing: Workspace.self) == "Workspace")
}
