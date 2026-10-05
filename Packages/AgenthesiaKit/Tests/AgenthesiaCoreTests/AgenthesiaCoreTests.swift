import Testing

@testable import AgenthesiaCore

@Test func moduleLoads() {
    #expect(String(describing: AgenthesiaCore.self) == "AgenthesiaCore")
}
