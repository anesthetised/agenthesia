import Foundation
import Synchronization
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct AgentRegistryHTTPTests {
    @Test func streamsAMetadataResponseAndPreservesTheValidator() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let response = try await RegistryHTTP.fetch(request("catalog"), session: session)
        #expect(response.status == 200)
        #expect(response.etag == #"W/"fixture""#)
        #expect(try AgentRegistry.Catalog(data: response.data).agents.count == 1)
    }

    @Test(arguments: ["declared-too-large", "stream-too-large"])
    func boundsBothDeclaredAndStreamedBodies(_ path: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: AgentRegistry.Failure.responseTooLarge) {
            try await RegistryHTTP.fetch(request(path), session: session)
        }
    }

    @Test func rejectsANonHTTPResponseAndDoesNotReadErrorBodies() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: AgentRegistry.Failure.invalidResponse) {
            try await RegistryHTTP.fetch(request("non-http"), session: session)
        }
        let failure = try await RegistryHTTP.fetch(request("unavailable"), session: session)
        #expect(failure.status == 503)
        #expect(failure.data.isEmpty)
        let unchanged = try await RegistryHTTP.fetch(request("not-modified"), session: session)
        #expect(unchanged.status == 304)
        #expect(unchanged.data.isEmpty)
    }

    @Test(arguments: [
        ("https://cdn.agentclientprotocol.com/other", true),
        ("http://cdn.agentclientprotocol.com/other", false),
        ("https://elsewhere.example/other", false),
        ("https://cdn.agentclientprotocol.com:8443/other", false),
        ("https://user:pass@cdn.agentclientprotocol.com/other", false),
    ]) func restrictsRedirectsToTheRegistryHTTPSOrigin(_ target: String, _ allowed: Bool) throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let redirected = URLRequest(url: try #require(URL(string: target)))
        let response = try #require(
            HTTPURLResponse(
                url: AgentRegistry.Client.endpoint,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let accepted = Mutex<Bool?>(nil)
        RegistryHTTP().urlSession(
            session,
            task: session.dataTask(with: request("catalog")),
            willPerformHTTPRedirection: response,
            newRequest: redirected,
            completionHandler: { result in accepted.withLock { $0 = result != nil } }
        )
        #expect(accepted.withLock { $0 } == allowed)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: AgentRegistry.Client.endpoint.deletingLastPathComponent().appending(path: path))
    }
}

// No mutable state is added to URLProtocol; each instance builds its own fixture response.
private final class RegistryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        if path == "non-http" {
            client?.urlProtocol(
                self,
                didReceive: URLResponse(
                    url: url,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                cacheStoragePolicy: .notAllowed
            )
        } else {
            let size = AgentRegistry.maximumBytes + 1
            let headers =
                path == "declared-too-large"
                ? ["Content-Length": String(size)] : ["ETag": #"W/"fixture""#]
            let status = path == "unavailable" ? 503 : path == "not-modified" ? 304 : 200
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
            else {
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = path == "stream-too-large" ? Data(repeating: 32, count: size) : registry([entry()])
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
