import Foundation
import JSONRPC
import Testing

@Suite struct LineFramerTests {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func splitsCompleteLines() {
        var framer = LineFramer()
        #expect(strings(framer.append(Data("a\nb\n".utf8))) == ["a", "b"])
        #expect(framer.finish() == nil)
    }

    @Test func joinsPartialChunks() {
        var framer = LineFramer()
        #expect(framer.append(Data("hel".utf8)).isEmpty)
        #expect(strings(framer.append(Data("lo\nwor".utf8))) == ["hello"])
        #expect(strings(framer.append(Data("ld\n".utf8))) == ["world"])
    }

    @Test func dropsCarriageReturnsAndEmptyLines() {
        var framer = LineFramer()
        #expect(strings(framer.append(Data("a\r\n\n\r\nb\n".utf8))) == ["a", "b"])
    }

    @Test func finishReturnsUnterminatedTail() {
        var framer = LineFramer()
        _ = framer.append(Data("a\ntail".utf8))
        #expect(framer.finish().map { String(decoding: $0, as: UTF8.self) } == "tail")
        #expect(framer.finish() == nil)
    }

    @Test func handlesLargeMessages() {
        var framer = LineFramer()
        let large = Data(repeating: 0x61, count: 5_000_000)
        var lines: [Data] = []
        for start in stride(from: 0, to: large.count, by: 65_536) {
            lines += framer.append(large[start..<min(start + 65_536, large.count)])
        }
        lines += framer.append(Data("\n".utf8))
        #expect(lines.count == 1)
        #expect(lines.first?.count == large.count)
    }

    @Test(arguments: [1, 2, 3, 42, 1234])
    func survivesArbitraryChunking(seed: UInt64) {
        let messages = (0..<50).map { #"{"id":\#($0),"text":"\#(String(repeating: "x", count: $0 * 7))"}"# }
        let stream = Data(messages.joined(separator: "\n").utf8) + Data("\n".utf8)
        var generator = SplitMix64(seed: seed)
        var framer = LineFramer()
        var received: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let length = Int.random(in: 1...97, using: &generator)
            let end = min(index + length, stream.endIndex)
            received += framer.append(stream[index..<end])
            index = end
        }
        #expect(strings(received) == messages)
    }
}

/// A small deterministic random number generator for reproducible tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
