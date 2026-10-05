import Testing

@testable import Rendering

@Test func moduleLoads() {
    #expect(String(describing: Rendering.self) == "Rendering")
}
