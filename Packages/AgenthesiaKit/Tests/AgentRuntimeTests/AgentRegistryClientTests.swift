import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct AgentRegistryClientTests {
    @Test func persistsAndConditionallyRevalidatesAcrossClientInstances() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]), etag: #""first""#)),
            .response(.init(status: 304, data: Data(), etag: #"W/"second""#)),
            .failure,
        ])
        let first = try await client(directory, server).refresh()
        #expect(first.source == .network)
        #expect(first.warning == nil)
        #expect(first.catalog.agents.first?.id == "example")
        let second = try await client(directory, server).refresh()
        #expect(second.source == .notModified)
        #expect(second.warning == nil)
        #expect(second.validatedAt >= first.validatedAt)
        let third = try await client(directory, server).refresh()
        #expect(third.source == .cache)
        #expect(third.warning == .networkUnavailable)
        #expect(third.validatedAt == second.validatedAt)
        let requests = await server.requests
        #expect(requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, #""first""#, #"W/"second""#])
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(requests.allSatisfy { $0.url?.absoluteString == AgentRegistry.Client.endpoint.absoluteString })
    }

    @Test func replacesTheCatalogAndClearsAnOmittedEtag() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]), etag: #""first""#)),
            .response(.init(status: 200, data: registry([entry(id: "replacement")]))),
            .failure,
        ])
        _ = try await client(directory, server).refresh()
        let result = try await client(directory, server).refresh()
        #expect(result.catalog.agents.map(\.id) == ["replacement"])
        let offline = try await client(directory, server).refresh()
        #expect(offline.catalog.agents.map(\.id) == ["replacement"])
        #expect(await server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func badResponsesPreserveTheLastValidCacheAndExposeTheFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]), etag: #""valid""#)),
            .response(.init(status: 503, data: Data())),
            .response(.init(status: 200, data: Data("broken".utf8))),
            .response(.init(status: 200, data: registry([], version: "2.0.0"))),
            .response(.init(status: 200, data: Data(repeating: 32, count: AgentRegistry.maximumBytes + 1))),
        ])
        _ = try await client(directory, server).refresh()
        for failure in [
            AgentRegistry.Failure.httpStatus(503), .invalidCatalog, .unsupportedVersion("2.0.0"), .responseTooLarge,
        ] {
            let result = try await client(directory, server).refresh()
            #expect(result.source == .cache)
            #expect(result.warning == failure)
            #expect(result.catalog.agents.map(\.id) == ["example"])
        }
        #expect(
            await server.requests.dropFirst().allSatisfy {
                $0.value(forHTTPHeaderField: "If-None-Match") == #""valid""#
            }
        )
    }

    @Test func missingOrCorruptCacheCannotTurnFailuresIntoSuccess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([.failure, .response(.init(status: 304, data: Data())), .failure])
        await #expect(throws: AgentRegistry.Failure.networkUnavailable) {
            try await client(directory, server).refresh()
        }
        await #expect(throws: AgentRegistry.Failure.notModifiedWithoutCache) {
            try await client(directory, server).refresh()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken cache".utf8).write(to: directory.appending(path: "registry-v1.json"))
        await #expect(throws: AgentRegistry.Failure.networkUnavailable) {
            try await client(directory, server).refresh()
        }
        #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    }

    @Test func anUnwritableCacheStillReturnsTheFetchedCatalogWithAWarning() async throws {
        let file = temporaryDirectory()
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = RegistryServer([.response(.init(status: 200, data: registry([entry()])))])
        let result = try await client(file, server).refresh()
        #expect(result.source == .network)
        #expect(result.warning == .cacheUnavailable)
        #expect(result.catalog.agents.count == 1)
    }

    @Test func rejectsHeaderInjectionAndDoesNotReuseAnUnvalidated304() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]), etag: "bad\r\nHeader: value")),
            .response(.init(status: 304, data: Data())),
        ])
        _ = try await client(directory, server).refresh()
        let result = try await client(directory, server).refresh()
        #expect(result.source == .cache)
        #expect(result.warning == .notModifiedWithoutCache)
        #expect(await server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func cancellationNeverReturnsStaleDataAndACancelledCallerDoesNotStartWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]))), .cancelled,
        ])
        _ = try await client(directory, server).refresh()
        await #expect(throws: CancellationError.self) { try await client(directory, server).refresh() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client(directory, server).refresh()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await server.requests.count == 2)
    }

    @Test func concurrentRefreshesShareWorkWhenOneWaiterIsCancelled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer(
            [.response(.init(status: 200, data: registry([entry()])))],
            delay: .milliseconds(100)
        )
        let client = client(directory, server)
        let cancelled = Task { try await client.refresh() }
        await server.waitForRequest()
        let result = try await withThrowingTaskGroup(of: AgentRegistry.Snapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await client.refresh() } }
            cancelled.cancel()
            var results: [AgentRegistry.Snapshot] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(result.count == 8)
        #expect(result.allSatisfy { $0.source == .network && $0.warning == nil })
        #expect(await server.requests.count == 1)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func cancellationTakesPrecedenceOverASharedNetworkFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([.failure], delay: .milliseconds(50))
        let client = client(directory, server)
        let cancelled = Task { try await client.refresh() }
        await server.waitForRequest()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func revalidatesTheCachedBodyBeforeSendingItsEtag() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RegistryServer([
            .response(.init(status: 200, data: registry([entry()]), etag: #""valid""#)),
            .response(.init(status: 304, data: Data())),
            .response(.init(status: 200, data: registry([]))),
        ])
        let client = client(directory, server)
        _ = try await client.refresh()
        let file = directory.appending(path: "registry-v1.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["data"] = Data("broken catalog".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        await #expect(throws: AgentRegistry.Failure.notModifiedWithoutCache) { try await client.refresh() }
        #expect(await server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
        try Data(repeating: 32, count: AgentRegistry.maximumBytes * 2 + 1).write(to: file)
        let recovered = try await client.refresh()
        #expect(recovered.source == .network)
        #expect(recovered.catalog.agents.isEmpty)
        #expect(recovered.warning == nil)
    }

    private func client(_ directory: URL, _ server: RegistryServer) -> AgentRegistry.Client {
        AgentRegistry.Client(cacheDirectory: directory, fetch: { try await server.respond($0) })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agenthesia-registry-\(UUID())")
    }
}

private actor RegistryServer {
    enum Outcome: Sendable {
        case response(AgentRegistry.Response)
        case failure
        case cancelled
    }
    private var outcomes: [Outcome]
    private let delay: Duration
    private(set) var requests: [URLRequest] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?

    init(_ outcomes: [Outcome], delay: Duration = .zero) {
        self.outcomes = outcomes
        self.delay = delay
    }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func respond(_ request: URLRequest) async throws -> AgentRegistry.Response {
        requests.append(request)
        requestWaiter?.resume()
        requestWaiter = nil
        if delay > .zero { try await Task.sleep(for: delay) }
        guard !outcomes.isEmpty else { throw URLError(.badServerResponse) }
        switch outcomes.removeFirst() {
        case .response(let response): return response
        case .failure: throw URLError(.notConnectedToInternet)
        case .cancelled: throw CancellationError()
        }
    }
}
