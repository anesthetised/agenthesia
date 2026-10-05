import ACP
import Foundation
import JSONRPC
import Testing

/// Round-trips every JSON-RPC example from the ACP documentation through the typed wire types.
@Suite struct WireFixtureTests {
    typealias Codec = @Sendable (JSONValue) throws -> JSONValue

    struct Codecs {
        var params: Codec
        var result: Codec?
    }

    static func codec<T: Codable & SendableMetatype>(_ type: T.Type) -> Codec {
        { try JSONValue(encoding: try $0.decode(as: T.self)) }
    }

    static func request<R: RPCRequest>(_ request: R.Type) -> (String, Codecs) {
        (R.method, Codecs(params: codec(R.Params.self), result: codec(R.Result.self)))
    }

    static func notification<N: RPCNotification>(_ notification: N.Type) -> (String, Codecs) {
        (N.method, Codecs(params: codec(N.Params.self), result: nil))
    }

    typealias M = ACP.V1.Method

    static let codecs: [String: Codecs] = Dictionary(
        uniqueKeysWithValues: [
            request(M.Initialize.self), request(M.Authenticate.self), request(M.Logout.self),
            request(M.NewSession.self), request(M.LoadSession.self), request(M.ResumeSession.self),
            request(M.ListSessions.self), request(M.DeleteSession.self), request(M.CloseSession.self),
            request(M.SetMode.self), request(M.SetConfigOption.self), request(M.Prompt.self),
            notification(M.Cancel.self), notification(M.SessionUpdate.self), request(M.RequestPermission.self),
            request(M.ReadTextFile.self), request(M.WriteTextFile.self), request(M.CreateTerminal.self),
            request(M.TerminalOutput.self), request(M.WaitForTerminalExit.self), request(M.KillTerminal.self),
            request(M.ReleaseTerminal.self), request(M.CreateElicitation.self),
            notification(M.CompleteElicitation.self),
        ]
    )

    static let files: [String] =
        (try? FileManager.default.contentsOfDirectory(
            atPath: Fixtures.directory.appending(path: "wire").path(percentEncoded: false)
        ))?.filter { $0.hasSuffix(".json") }.sorted() ?? []

    @Test func fixturesExist() {
        #expect(Self.files.count >= 10)
    }

    @Test(arguments: files)
    func roundTripsDocumentationExamples(file: String) throws {
        let fixture = try Fixtures.json("wire/\(file)")
        let entries = try #require(fixture["entries"]?.arrayValue)
        for (index, entry) in entries.enumerated() {
            let method = try #require(entry["method"]?.stringValue)
            let kind = try #require(entry["kind"]?.stringValue)
            let value = try #require(entry["value"])
            let codecs = try #require(Self.codecs[method], "No codec for \(method)")
            let codec = try #require(kind == "result" ? codecs.result : codecs.params)
            do {
                let encoded = try codec(value)
                #expect(
                    encoded.normalized == value.normalized,
                    "\(file)#\(index) \(method) \(kind)\nGOT  \(encoded.compact)\nWANT \(value.compact)"
                )
            } catch {
                Issue.record("\(file)#\(index) \(method) \(kind): \(error)")
            }
        }
    }
}
