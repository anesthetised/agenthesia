import CryptoKit
import Foundation

// Compile with the application's actual generator; validates the standalone fixture copy.
@main
struct FixtureIdentity {
    static func main() throws {
        let text = TranscriptGenerator.swiftFile(lines: 10_000)
        let identity: [String: Any] = [
            "fixtureUTF16Count": text.utf16.count,
            "fixtureSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
        ]
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
