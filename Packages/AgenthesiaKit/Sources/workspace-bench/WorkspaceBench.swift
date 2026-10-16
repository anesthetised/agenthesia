import Foundation
import Workspace

/// Initial timings for file discovery, fuzzy search, changed paths and bounded reads.
/// Three sequential runs reuse one fixture: later runs may benefit from OS and Git caches.
@main
struct WorkspaceBench {
    enum Failure: Error {
        case git(String)
        case validation(String)
    }

    struct Run: Encodable {
        let run: Int
        let indexMilliseconds: Double
        let queryMilliseconds: Double
        let changesMilliseconds: Double
        let readMilliseconds: Double
        let indexedFiles: Int
        let queries: Int
        let matchingPaths: Int
        let changedPaths: Int
        let readBytes: Int
    }

    struct Report: Encodable {
        let workload: String
        let fixtureCreationTimed: Bool
        let cachePolicy: String
        let shortFiles: Int
        let largeFileBytes: Int
        let committedChanges: Int
        let unstagedChanges: Int
        let validationPassed: Bool
        let runs: [Run]
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agenthesia-workspace-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Setup is deliberately outside every measured interval. Git never runs project hooks.
        _ = try git(["init", "--quiet", "--template="], in: directory)
        for group in 0..<100 {
            try FileManager.default.createDirectory(
                at: directory.appending(path: String(format: "src/group%03d", group)),
                withIntermediateDirectories: true
            )
        }
        for number in 0..<10_000 {
            try Data("let value = \(number)\n".utf8).write(to: directory.appending(path: path(number)))
        }
        let byteCount = 2 * 1024 * 1024
        let largeFile = directory.appending(path: "large.txt")
        try Data(repeating: 0x61, count: byteCount).write(to: largeFile)
        _ = try git(["add", "--all"], in: directory)
        _ = try git(["commit", "--quiet", "-m", "Benchmark baseline"], in: directory)
        let base = try git(["rev-parse", "--verify", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for number in 0..<50 {
            try Data("let committed = \(number)\n".utf8).write(to: directory.appending(path: path(number)))
        }
        _ = try git(["add", "--all"], in: directory)
        _ = try git(["commit", "--quiet", "-m", "Benchmark committed changes"], in: directory)
        for number in 50..<100 {
            try Data("let unstaged = \(number)\n".utf8).write(to: directory.appending(path: path(number)))
        }

        let queries = (0..<20).map { String(format: "f%05ds", $0 * 499) }
        let expectedChanges = Set((0..<100).map(path))
        let access = ScopedFileAccess(roots: [directory])
        let clock = ContinuousClock()
        var runs: [Run] = []
        for number in 1...3 {
            let indexStart = clock.now
            let index = try await FileIndex.load(in: directory)
            let indexDuration = indexStart.duration(to: clock.now)
            guard index.paths.count == 10_001 else { throw Failure.validation("Expected 10001 indexed files") }

            let queryStart = clock.now
            var matches: [[String]] = []
            for query in queries { matches.append(try index.matching(query)) }
            let queryDuration = queryStart.duration(to: clock.now)
            for (offset, result) in matches.enumerated() {
                guard result == [path(offset * 499)] else {
                    throw Failure.validation("Fuzzy query did not return its known target")
                }
            }

            let changesStart = clock.now
            let changes = try await SessionWorkspace.changedPaths(in: directory, baseRevision: base)
            let changesDuration = changesStart.duration(to: clock.now)
            guard changes.count == 100, Set(changes) == expectedChanges else {
                throw Failure.validation("Expected all 50 committed and 50 unstaged changes")
            }

            let readStart = clock.now
            let text = try access.readText(at: largeFile.path(percentEncoded: false), maximumBytes: byteCount)
            let readDuration = readStart.duration(to: clock.now)
            guard text.utf8.count == byteCount, text.utf8.allSatisfy({ $0 == 0x61 }) else {
                throw Failure.validation("Bounded read did not return the complete 2 MiB UTF-8 file")
            }
            runs.append(
                Run(
                    run: number,
                    indexMilliseconds: milliseconds(indexDuration),
                    queryMilliseconds: milliseconds(queryDuration),
                    changesMilliseconds: milliseconds(changesDuration),
                    readMilliseconds: milliseconds(readDuration),
                    indexedFiles: index.paths.count,
                    queries: queries.count,
                    matchingPaths: matches.reduce(0) { $0 + $1.count },
                    changedPaths: changes.count,
                    readBytes: text.utf8.count
                )
            )
        }
        let report = Report(
            workload: "10000 short files, one 2 MiB UTF-8 file, 100 changed paths, 20 fuzzy queries, 3 sequential runs",
            fixtureCreationTimed: false,
            cachePolicy: "One fixture reused; no cache eviction or warm-up. Later runs may use OS and Git caches.",
            shortFiles: 10_000,
            largeFileBytes: byteCount,
            committedChanges: 50,
            unstagedChanges: 50,
            validationPassed: true,
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(report)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func path(_ number: Int) -> String {
        String(format: "src/group%03d/file%05d.swift", number / 100, number)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments =
            [
                "-c", "core.hooksPath=/dev/null",
                "-c", "core.excludesFile=/dev/null",
                "-c", "commit.gpgSign=false",
                "-c", "user.name=Agenthesia Benchmark",
                "-c", "user.email=benchmark@invalid",
            ] + arguments
        // Inherited GIT_DIR/WORK_TREE/INDEX_FILE must never redirect fixture writes elsewhere.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.git(text) }
        return text
    }
}
