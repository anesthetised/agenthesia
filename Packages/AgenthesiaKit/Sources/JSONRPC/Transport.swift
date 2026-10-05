public import Foundation
import Synchronization

/// A bidirectional stream of JSON-RPC messages, one message per line.
public protocol MessageTransport: Sendable {
    /// Incoming messages, without line terminators. Has a single consumer.
    var messages: AsyncThrowingStream<Data, any Error> { get }

    /// Sends one message. The transport appends the line terminator.
    func send(_ message: Data) async throws

    /// Closes the transport. Incoming messages finish.
    func close() async
}

/// A transport over a pair of file handles, typically a child process's stdout and stdin.
public final class FileHandleTransport: MessageTransport {
    public let messages: AsyncThrowingStream<Data, any Error>
    private let reading: FileHandle
    private let writing: FileHandle
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let writeQueue = DispatchQueue(label: "io.github.anesthetised.Agenthesia.FileHandleTransport.write")

    public init(reading: FileHandle, writing: FileHandle) {
        self.reading = reading
        self.writing = writing
        let (messages, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.messages = messages
        self.continuation = continuation

        let framer = LockedFramer()
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let rest = framer.finish() {
                    continuation.yield(rest)
                }
                continuation.finish()
            } else {
                for message in framer.append(chunk) {
                    continuation.yield(message)
                }
            }
        }
    }

    public func send(_ message: Data) async throws {
        let line = message + [0x0A]
        let writing = writing
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                do {
                    try writing.write(contentsOf: line)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        reading.readabilityHandler = nil
        try? writing.close()
        continuation.finish()
    }
}

/// A `LineFramer` shared between the readability handler's invocations.
private final class LockedFramer: Sendable {
    private let framer = Mutex(LineFramer())

    func append(_ chunk: Data) -> [Data] {
        framer.withLock { $0.append(chunk) }
    }

    func finish() -> Data? {
        framer.withLock { $0.finish() }
    }
}

/// An in-process transport, for tests.
public final class InMemoryTransport: MessageTransport {
    public let messages: AsyncThrowingStream<Data, any Error>
    private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
    private let outgoing: AsyncThrowingStream<Data, any Error>.Continuation

    private init(
        messages: AsyncThrowingStream<Data, any Error>,
        incoming: AsyncThrowingStream<Data, any Error>.Continuation,
        outgoing: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.messages = messages
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// Two transports connected to each other.
    public static func pair() -> (InMemoryTransport, InMemoryTransport) {
        let (a, aContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (b, bContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        return (
            InMemoryTransport(messages: a, incoming: aContinuation, outgoing: bContinuation),
            InMemoryTransport(messages: b, incoming: bContinuation, outgoing: aContinuation)
        )
    }

    public func send(_ message: Data) async throws {
        guard case .enqueued = outgoing.yield(message) else {
            throw ConnectionError.closed
        }
    }

    public func close() async {
        incoming.finish()
        outgoing.finish()
    }
}
