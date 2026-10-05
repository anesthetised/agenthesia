import Foundation
import JSONRPC
import Testing

@Suite struct InMemoryTransportTests {
    @Test func deliversToPeer() async throws {
        let (a, b) = InMemoryTransport.pair()
        try await a.send(Data("one".utf8))
        try await b.send(Data("two".utf8))
        var aIterator = a.messages.makeAsyncIterator()
        var bIterator = b.messages.makeAsyncIterator()
        #expect(try await bIterator.next() == Data("one".utf8))
        #expect(try await aIterator.next() == Data("two".utf8))
    }

    @Test func closeFinishesBothSidesAndRejectsSends() async throws {
        let (a, b) = InMemoryTransport.pair()
        await a.close()
        var aIterator = a.messages.makeAsyncIterator()
        var bIterator = b.messages.makeAsyncIterator()
        #expect(try await aIterator.next() == nil)
        #expect(try await bIterator.next() == nil)
        await #expect(throws: ConnectionError.closed) { try await a.send(Data("x".utf8)) }
    }
}

@Suite struct FileHandleTransportTests {
    @Test func writesNewlineTerminatedMessages() async throws {
        let toPeer = Pipe()
        let fromPeer = Pipe()
        let transport = FileHandleTransport(
            reading: fromPeer.fileHandleForReading,
            writing: toPeer.fileHandleForWriting
        )
        try await transport.send(Data(#"{"a":1}"#.utf8))
        try await transport.send(Data(#"{"b":2}"#.utf8))
        await transport.close()
        let written = try toPeer.fileHandleForReading.readToEnd() ?? Data()
        #expect(String(decoding: written, as: UTF8.self) == "{\"a\":1}\n{\"b\":2}\n")
    }

    @Test func readsFramedMessagesUntilEndOfFile() async throws {
        let toPeer = Pipe()
        let fromPeer = Pipe()
        let transport = FileHandleTransport(
            reading: fromPeer.fileHandleForReading,
            writing: toPeer.fileHandleForWriting
        )
        try fromPeer.fileHandleForWriting.write(contentsOf: Data("first\nsec".utf8))
        try fromPeer.fileHandleForWriting.write(contentsOf: Data("ond\r\nthird".utf8))
        try fromPeer.fileHandleForWriting.close()

        var received: [String] = []
        for try await message in transport.messages {
            received.append(String(decoding: message, as: UTF8.self))
        }
        #expect(received == ["first", "second", "third"])
    }

    @Test func sendFailsAfterClose() async throws {
        let toPeer = Pipe()
        let fromPeer = Pipe()
        let transport = FileHandleTransport(
            reading: fromPeer.fileHandleForReading,
            writing: toPeer.fileHandleForWriting
        )
        await transport.close()
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
        var iterator = transport.messages.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }
}
