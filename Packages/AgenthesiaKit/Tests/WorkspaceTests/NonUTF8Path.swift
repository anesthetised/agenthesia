import Foundation

@testable import Workspace

/// APFS rejects non-UTF-8 filenames, but Git can still record one, e.g. from another file system's clone.
func stageNonUTF8Path(in directory: URL) async throws {
    try "content".write(to: directory.appending(path: "blob-source"), atomically: true, encoding: .utf8)
    let blob = try await SessionWorkspace.git(["hash-object", "-w", "blob-source"], in: directory)
    try FileManager.default.removeItem(at: directory.appending(path: "blob-source"))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
                with: Result {
                    let process = Process()
                    process.executableURL = URL(filePath: "/bin/sh")
                    process.currentDirectoryURL = directory
                    process.arguments = [
                        "-c", "printf '100644 %s\\tbad\\377name\\n' \(blob) | /usr/bin/git update-index --index-info",
                    ]
                    process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                }
            )
        }
    }
}
