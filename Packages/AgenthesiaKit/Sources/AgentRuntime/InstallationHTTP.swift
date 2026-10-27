import Foundation

/// Release assets may redirect to a CDN. Every hop must remain credential-free HTTPS.
final class InstallationHTTP: NSObject, URLSessionTaskDelegate {
    static func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int = 268_435_456,
        session supplied: URLSession? = nil
    ) async throws {
        guard allowed(url) else { throw AgentInstallation.Failure.downloadFailed }
        try Task.checkCancellation()
        let session: URLSession
        if let supplied {
            session = supplied
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 300
            session = URLSession(configuration: configuration, delegate: InstallationHTTP(), delegateQueue: nil)
        }
        defer { if supplied == nil { session.invalidateAndCancel() } }
        var completed = false
        var created = false
        defer { if created && !completed { try? FileManager.default.removeItem(at: destination) } }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                let finalURL = response.url, allowed(finalURL)
            else { throw AgentInstallation.Failure.downloadFailed }
            guard response.expectedContentLength <= maximumBytes else {
                throw AgentInstallation.Failure.downloadTooLarge
            }
            try Data().write(to: destination, options: .withoutOverwriting)
            created = true
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(65_536)
            var count = 0
            for try await byte in bytes {
                guard count < maximumBytes else { throw AgentInstallation.Failure.downloadTooLarge }
                count += 1
                buffer.append(byte)
                if buffer.count == 65_536 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            try handle.write(contentsOf: buffer)
            try handle.close()
            completed = true
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw (error as? AgentInstallation.Failure) ?? AgentInstallation.Failure.downloadFailed
        }
    }

    static func allowed(_ url: URL) -> Bool {
        AgentRegistry.safeURL(url, httpsOnly: true) && (url.port == nil || url.port == 443)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.allowed(url) else { completionHandler(nil); return }
        // Rebuild the request so an origin's headers cannot be forwarded to another host.
        completionHandler(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
}
