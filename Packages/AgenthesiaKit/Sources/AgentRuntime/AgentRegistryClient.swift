public import Foundation

extension AgentRegistry {
    public struct Snapshot: Sendable {
        public enum Source: Equatable, Sendable { case network, notModified, cache }

        public let catalog: Catalog
        public let source: Source
        /// Last successful download or conditional validation, retained when serving stale data.
        public let validatedAt: Date
        /// A failed refresh or cache write is explicit even when the catalog is usable.
        public let warning: Failure?
    }

    /// One client per cache directory; concurrent refreshes share one bounded request.
    public actor Client {
        public static let endpoint: URL = {
            guard let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json") else {
                preconditionFailure("Invalid built-in registry URL")
            }
            return url
        }()

        private let cacheFile: URL
        private let fetch: @Sendable (URLRequest) async throws -> Response
        private var inFlight: Task<Snapshot, any Error>?

        public init(cacheDirectory: URL) {
            self.init(cacheDirectory: cacheDirectory, fetch: { try await RegistryHTTP.fetch($0) })
        }

        init(cacheDirectory: URL, fetch: @escaping @Sendable (URLRequest) async throws -> Response) {
            cacheFile = cacheDirectory.appending(path: "registry-v1.json")
            self.fetch = fetch
        }

        /// Returns validated metadata or a last-known-good catalog with a warning. Cancellation throws.
        /// Cancelling one waiter does not cancel a refresh shared with other callers.
        public func refresh() async throws -> Snapshot {
            try Task.checkCancellation()
            if let inFlight {
                let result = await inFlight.result
                try Task.checkCancellation()
                return try result.get()
            }
            let cacheFile = cacheFile
            let fetch = fetch
            let task = Task.detached { try await Self.load(cacheFile: cacheFile, fetch: fetch) }
            inFlight = task
            defer { inFlight = nil }
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }

        private static func load(
            cacheFile: URL,
            fetch: @Sendable (URLRequest) async throws -> Response
        ) async throws -> Snapshot {
            let cached = await Record.read(at: cacheFile)
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(validETag(cached?.record.etag), forHTTPHeaderField: "If-None-Match")
            let record: Record
            let catalog: Catalog
            let source: Snapshot.Source
            do {
                let response = try await fetch(request)
                switch response.status {
                case 200:
                    catalog = try Catalog(data: response.data)
                    record = Record(data: response.data, etag: validETag(response.etag), validatedAt: Date())
                    source = .network
                case 304:
                    guard let cached, request.value(forHTTPHeaderField: "If-None-Match") != nil else {
                        throw Failure.notModifiedWithoutCache
                    }
                    catalog = cached.catalog
                    record = Record(
                        data: cached.record.data,
                        etag: validETag(response.etag) ?? cached.record.etag,
                        validatedAt: Date()
                    )
                    source = .notModified
                default:
                    throw Failure.httpStatus(response.status)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                let failure = (error as? Failure) ?? .networkUnavailable
                guard let cached else { throw failure }
                return Snapshot(
                    catalog: cached.catalog,
                    source: .cache,
                    validatedAt: cached.record.validatedAt,
                    warning: failure
                )
            }
            let saved = await record.write(to: cacheFile)
            return Snapshot(
                catalog: catalog,
                source: source,
                validatedAt: record.validatedAt,
                warning: saved ? nil : .cacheUnavailable
            )
        }

        private static func validETag(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 1_024,
                value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
            else { return nil }
            return value
        }

        /// Body and validator are replaced together so a failed write cannot pair an old catalog with a new ETag.
        private struct Record: Codable, Sendable {
            let data: Data
            let etag: String?
            let validatedAt: Date

            static func read(at url: URL) async -> (record: Self, catalog: Catalog)? {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let result: (Self, Catalog)? = try? {
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            // JSON encodes the original body as base64. Bound the envelope before decoding too.
                            let limit = maximumBytes * 2
                            guard let bytes = try handle.read(upToCount: limit + 1), bytes.count <= limit else {
                                throw Failure.responseTooLarge
                            }
                            let record = try JSONDecoder().decode(Self.self, from: bytes)
                            return (record, try Catalog(data: record.data))
                        }()
                        continuation.resume(returning: result)
                    }
                }
            }

            func write(to url: URL) async -> Bool {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let bytes = try JSONEncoder().encode(self)
                            try FileManager.default.createDirectory(
                                at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try bytes.write(to: url, options: .atomic)
                            continuation.resume(returning: true)
                        } catch {
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
        }
    }

    struct Response: Sendable {
        let status: Int
        let data: Data
        var etag: String? = nil
    }
}

/// Fetch only metadata over HTTPS; no URLCache, cookies or credentials are shared with other app traffic.
final class RegistryHTTP: NSObject, URLSessionTaskDelegate {
    static func fetch(
        _ request: URLRequest,
        session suppliedSession: URLSession? = nil
    ) async throws -> AgentRegistry.Response {
        let session: URLSession
        if let suppliedSession {
            session = suppliedSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 60
            session = URLSession(configuration: configuration, delegate: RegistryHTTP(), delegateQueue: nil)
        }
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
            let url = response.url, AgentRegistry.safeURL(url, httpsOnly: true)
        else { throw AgentRegistry.Failure.invalidResponse }
        var data = Data()
        if response.statusCode == 200 {
            guard response.expectedContentLength <= AgentRegistry.maximumBytes else {
                throw AgentRegistry.Failure.responseTooLarge
            }
            for try await byte in bytes {
                guard data.count < AgentRegistry.maximumBytes else { throw AgentRegistry.Failure.responseTooLarge }
                data.append(byte)
            }
        }
        return AgentRegistry.Response(
            status: response.statusCode,
            data: data,
            etag: response.value(forHTTPHeaderField: "ETag")
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Registry metadata has one origin; do not follow a redirect to another host or to plain HTTP.
        let allowed =
            request.url?.host == AgentRegistry.Client.endpoint.host
            && (request.url?.port == nil || request.url?.port == 443)
            && request.url.map({ AgentRegistry.safeURL($0, httpsOnly: true) }) == true
        completionHandler(allowed ? request : nil)
    }
}
