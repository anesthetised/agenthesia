import ACP
import Foundation
import Testing

/// Checks the vendored schema the wire types are written against.
@Suite struct SchemaTests {
    static let schemaDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../Resources/acp-schema")
        .standardized

    @Test func vendoredSchemaMatchesProtocolVersion() throws {
        let data = try Data(contentsOf: Self.schemaDirectory.appending(path: "meta.json"))
        let meta = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(meta["version"] as? Int == ACP.V1.protocolVersion)
    }
}
