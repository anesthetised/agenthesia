import CoreServices
public import Foundation

/// Advisory invalidation only: callers rescan authoritative state, including after dropped or coalesced events.
@MainActor public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let callback: Callback

    /// `excluding` drops events below up to eight absolute directories, the FSEvents limit.
    public init(
        directories: [URL],
        excluding: [URL] = [],
        onChange: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let isValid: (URL) -> Bool = {
            let path = $0.path(percentEncoded: false)
            return $0.isFileURL && path.hasPrefix("/") && !path.utf8.contains(0)
        }
        guard !directories.isEmpty, excluding.count <= 8, directories.allSatisfy(isValid), excluding.allSatisfy(isValid)
        else {
            throw SessionWorkspace.WorkspaceError(message: "File watching requires at least one absolute directory.")
        }
        callback = Callback(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard
            let stream = FSEventStreamCreate(
                nil,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
                    // The stream is scheduled exclusively on DispatchQueue.main; close and callbacks cannot race.
                    MainActor.assumeIsolated { callback.onChange() }
                },
                &context,
                directories.map { $0.path(percentEncoded: false) } as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            )
        else { throw SessionWorkspace.WorkspaceError(message: "Could not create file watching.") }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard
            excluding.isEmpty
                || FSEventStreamSetExclusionPaths(stream, excluding.map { $0.path(percentEncoded: false) } as CFArray),
            FSEventStreamStart(stream)
        else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw SessionWorkspace.WorkspaceError(message: "Could not start file watching.")
        }
        self.stream = stream
    }

    /// Idempotent. No callback can run after this returns.
    public func close() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    isolated deinit { close() }

    @MainActor private final class Callback {
        let onChange: @MainActor @Sendable () -> Void

        init(onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    }
}
