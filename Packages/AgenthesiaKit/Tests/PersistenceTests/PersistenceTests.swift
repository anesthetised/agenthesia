import Testing

@testable import Persistence

@Test func moduleLoads() {
    #expect(String(describing: Persistence.self) == "Persistence")
}
