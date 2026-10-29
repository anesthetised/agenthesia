/// Readable text for a failed prompt, formatted when displayed so saved history benefits too.
public enum PromptFailure {
    /// The `message` of a stored `RPCError(code:message:data:)` description; any other text is returned unchanged.
    public static func summary(_ stored: String) -> String {
        guard stored.hasPrefix("RPCError(code: "), let start = stored.range(of: ", message: \"") else { return stored }
        var message = ""
        var characters = stored[start.upperBound...].makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"": return message
            case "\\":
                guard let escaped = characters.next() else { return stored }
                switch escaped {
                case "n": message.append("\n")
                case "t": message.append("\t")
                case "r": message.append("\r")
                case "0": message.append("\0")
                case "u":
                    // `\u{1F600}`
                    guard characters.next() == "{" else { return stored }
                    var digits = ""
                    while let next = characters.next(), next != "}" { digits.append(next) }
                    guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
                        return stored
                    }
                    message.unicodeScalars.append(scalar)
                default: message.append(escaped)
                }
            default: message.append(character)
            }
        }
        return stored
    }
}
