import ACP
import Foundation
import JSONRPC
import Testing

/// Checks the implementation against the vendored ACP schema (`Resources/acp-schema`).
@Suite struct SchemaTests {
    static let schemaDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../Resources/acp-schema")
        .standardized

    /// Methods of the schema this client deliberately does not implement, with the reason.
    static let unsupported: [String: String] = [:]

    private func meta() throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: Self.schemaDirectory.appending(path: "meta.json"))
        )
    }

    private func methods(_ group: String) throws -> Set<String> {
        let methods = try #require(try meta()[group]?.objectValue)
        return Set(methods.values.compactMap(\.stringValue))
    }

    @Test func vendoredSchemaMatchesProtocolVersion() throws {
        #expect(try meta()["version"]?.intValue.map(Int.init) == ACP.V1.protocolVersion)
    }

    @Test func implementsEveryAgentMethod() throws {
        let schema = try methods("agentMethods")
        let implemented = Set(ACP.V1.agentMethods)
        #expect(
            implemented.subtracting(schema).isEmpty,
            "Methods not in the schema: \(implemented.subtracting(schema))"
        )
        #expect(schema.subtracting(implemented).subtracting(Self.unsupported.keys).isEmpty)
    }

    @Test func implementsEveryClientMethod() throws {
        let schema = try methods("clientMethods")
        let declared = Set(ACP.V1.clientMethods)
        #expect(declared == schema.subtracting(Self.unsupported.keys))

        // The router built for a delegate handles exactly the declared methods.
        struct Silent: ACP.V1.ClientDelegate {}
        let router = ACP.V1.router(for: Silent())
        #expect(router.requestMethods.union(router.notificationMethods) == declared)
    }

    @Test func handlesProtocolMethods() throws {
        #expect(try methods("protocolMethods") == Set(ACP.V1.protocolMethods))
    }

    @Test func everySchemaMethodHasATypedParamsType() throws {
        let schema = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: Self.schemaDirectory.appending(path: "schema.json"))
        )
        let definitions = try #require(schema["$defs"]?.objectValue)
        let documented = Set(definitions.values.compactMap { $0["x-method"]?.stringValue })
        let all = Set(ACP.V1.agentMethods + ACP.V1.clientMethods + ACP.V1.protocolMethods)
        #expect(documented.subtracting(all).subtracting(Self.unsupported.keys).isEmpty)
    }
}
