import Foundation

/// Reads lines from a stream, one caller at a time. Waiting for a line can be cancelled without losing
/// the stream.
actor LineReader {
    private var lines: [String] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<String?, Never>)?
    private var nextWaiterID = 0
    private var isFinished = false

    init<Lines: AsyncSequence & Sendable>(_ source: Lines) where Lines.Element == String {
        Task { [weak self] in
            do {
                for try await line in source {
                    await self?.receive(line)
                }
            } catch {}
            await self?.finish()
        }
    }

    /// Lines from standard input.
    static func standardInput() -> LineReader {
        LineReader(FileHandle.standardInput.bytes.lines)
    }

    /// The next line, or `nil` at the end of the stream or when the calling task is cancelled.
    func next() async -> String? {
        if !lines.isEmpty { return lines.removeFirst() }
        guard !isFinished, !Task.isCancelled else { return nil }
        nextWaiterID += 1
        let id = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = (id, $0) }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Makes a pending `next()` return `nil` now, as if the user gave no answer.
    func interrupt() {
        waiter?.continuation.resume(returning: nil)
        waiter = nil
    }

    private func receive(_ line: String) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: line)
        } else {
            lines.append(line)
        }
    }

    private func finish() {
        isFinished = true
        waiter?.continuation.resume(returning: nil)
        waiter = nil
    }

    private func abandon(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
