public import Foundation

/// Text an agent reads from a terminal's raw output (ADR-0015).
///
/// Escape sequences are removed, CRLF becomes LF, and a carriage return inside a line keeps only the
/// text after it, so progress bars collapse to their last state. Other control characters except tab
/// are dropped. This is a heuristic, not a terminal emulator: cursor movement is not interpreted.
public enum TerminalText {
    public struct Result: Sendable, Hashable {
        public var text: String
        /// Whether output was lost, either before reaching `make` or by the byte limit.
        public var truncated: Bool

        public init(text: String, truncated: Bool) {
            self.text = text
            self.truncated = truncated
        }
    }

    /// Cuts from the start at a character boundary so that the text is at most `byteLimit` UTF-8 bytes.
    /// An incomplete trailing escape sequence or character, from a command still running, is withheld.
    public static func make(from output: TerminalOutput, byteLimit: Int) -> Result {
        var bytes = collapseCarriageReturns(stripEscapes(Array(output.bytes)))
        var truncated = output.truncated
        // A byte limit on the raw output can cut into a scalar.
        var start = 0
        if output.truncated { start = continuationRun(bytes, from: 0) }
        if bytes.count - start > byteLimit {
            truncated = true
            start = continuationRun(bytes, from: bytes.count - max(0, byteLimit))
        }
        bytes = Array(bytes[start...])
        bytes.removeLast(incompleteSuffix(bytes))
        return Result(text: String(decoding: bytes, as: UTF8.self), truncated: truncated)
    }

    private static func stripEscapes(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard byte == 0x1B else {
                if byte >= 0x20 && byte != 0x7F || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                    result.append(byte)
                }
                i += 1
                continue
            }
            guard i + 1 < bytes.count else { break }
            let kind = bytes[i + 1]
            var j = i + 2
            switch kind {
            case UInt8(ascii: "["):
                while j < bytes.count && !(0x40...0x7E).contains(bytes[j]) { j += 1 }
                j += 1
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                // A string ends with ST (ESC \); OSC also accepts BEL.
                while j < bytes.count {
                    if kind == UInt8(ascii: "]") && bytes[j] == 0x07 {
                        j += 1
                        break
                    }
                    if bytes[j] == 0x1B && j + 1 < bytes.count && bytes[j + 1] == UInt8(ascii: "\\") {
                        j += 2
                        break
                    }
                    j += 1
                }
            default:
                j = i + 1
                while j < bytes.count && (0x20...0x2F).contains(bytes[j]) { j += 1 }
                j += 1
            }
            i = j
        }
        return result
    }

    private static func collapseCarriageReturns(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x0D) else { return bytes }
        var result: [UInt8] = []
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(0x0A) }
            result.append(
                contentsOf: line.split(separator: 0x0D, omittingEmptySubsequences: true).last ?? []
            )
        }
        return result
    }

    private static func continuationRun(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count && bytes[index] & 0xC0 == 0x80 { index += 1 }
        return index
    }

    /// The length of a trailing partial UTF-8 scalar, if any.
    private static func incompleteSuffix(_ bytes: [UInt8]) -> Int {
        for back in 1...3 where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return back < expected ? back : 0
        }
        return 0
    }
}
