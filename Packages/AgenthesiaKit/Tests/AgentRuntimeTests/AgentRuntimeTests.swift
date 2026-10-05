import Testing

@testable import AgentRuntime

@Test func moduleLoads() {
    #expect(String(describing: AgentRuntime.self) == "AgentRuntime")
}
