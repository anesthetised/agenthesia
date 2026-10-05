public import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// Chunks may split messages at arbitrary positions. A trailing `\r` is dropped, empty lines are skipped.
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns all messages it completes.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if let line = Self.trimmed(buffer[start..<newline]) {
                lines.append(line)
            }
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return lines
    }

    /// Returns the unterminated message left in the buffer at the end of the stream, if any.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return Self.trimmed(buffer[...])
    }

    private static func trimmed(_ line: Data.SubSequence) -> Data? {
        var line = line
        if line.last == 0x0D {
            line = line.dropLast()
        }
        return line.isEmpty ? nil : Data(line)
    }
}
