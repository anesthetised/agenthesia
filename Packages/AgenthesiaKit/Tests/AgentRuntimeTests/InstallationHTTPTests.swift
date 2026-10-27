import Foundation
import Synchronization
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct InstallationHTTPTests {
    @Test func downloadsIntoANewFileAndRefusesToOverwrite() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let target = fixture.root.appending(path: "download")
        try await InstallationHTTP.download(url("ok"), to: target, maximumBytes: 8, session: session)
        #expect(try Data(contentsOf: target) == Data("archive".utf8))
        await #expect(throws: AgentInstallation.Failure.downloadFailed) {
            try await InstallationHTTP.download(url("ok"), to: target, maximumBytes: 8, session: session)
        }
        #expect(try Data(contentsOf: target) == Data("archive".utf8))
    }

    @Test(arguments: ["declared", "streamed"])
    func sizeFailuresLeaveNoDownload(_ path: String) async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let target = fixture.root.appending(path: "download")
        await #expect(throws: AgentInstallation.Failure.downloadTooLarge) {
            try await InstallationHTTP.download(url(path), to: target, maximumBytes: 8, session: session)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test(arguments: ["non-http", "failure"])
    func rejectsInvalidResponses(_ path: String) async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: AgentInstallation.Failure.downloadFailed) {
            try await InstallationHTTP.download(
                url(path),
                to: fixture.root.appending(path: "download"),
                session: session
            )
        }
    }

    @Test(arguments: [
        ("https://release-assets.example/agent", true), ("http://release-assets.example/agent", false),
        ("https://user:pass@release-assets.example/agent", false), ("https://release-assets.example:8443/agent", false),
    ]) func redirectsRemainHTTPSAndDropOriginHeaders(_ target: String, _ allowed: Bool) throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var redirected = URLRequest(url: try #require(URL(string: target)))
        redirected.setValue("secret", forHTTPHeaderField: "Authorization")
        let response = try #require(
            HTTPURLResponse(url: url("ok"), statusCode: 302, httpVersion: nil, headerFields: nil)
        )
        let accepted = Mutex<URLRequest?>(nil)
        InstallationHTTP().urlSession(
            session,
            task: session.dataTask(with: url("ok")),
            willPerformHTTPRedirection: response,
            newRequest: redirected,
            completionHandler: { request in accepted.withLock { $0 = request } }
        )
        #expect(accepted.withLock { $0 != nil } == allowed)
        #expect(accepted.withLock { $0?.value(forHTTPHeaderField: "Authorization") } == nil)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallationProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func url(_ path: String) -> URL { AgentRegistry.Client.endpoint.appending(path: path) }
}

// Each URLProtocol instance uses only its immutable request; no mutable shared fixture state.
private final class InstallationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        let response: URLResponse
        if path == "non-http" {
            response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        } else {
            guard
                let http = HTTPURLResponse(
                    url: url,
                    statusCode: path == "failure" ? 503 : 200,
                    httpVersion: nil,
                    headerFields: path == "declared" ? ["Content-Length": "9"] : nil
                )
            else { return }
            response = http
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((path == "streamed" ? "123456789" : "archive").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
