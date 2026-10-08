import Foundation
import Persistence

// Fixed, bounded workload: just bench-persistence. Rate zero measures saturation throughput.
enum BenchmarkError: Error { case invalidArguments, replayMismatch }

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
}

guard CommandLine.arguments.count == 3,
    let batchSize = Int(CommandLine.arguments[1]), [1, 16, 64].contains(batchSize),
    let rate = Int(CommandLine.arguments[2]), [0, 100, 1000].contains(rate)
else { throw BenchmarkError.invalidArguments }

let directory = FileManager.default.temporaryDirectory.appending(path: "agenthesia-bench-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appending(path: "sessions.sqlite")
let store = try PersistenceStore(databaseURL: url)
let project = ProjectRecord(name: "Benchmark", rootPath: directory.path())
let agent = AgentInstallRecord(name: "Benchmark", executable: "/unused")
let session = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: project.rootPath)
try await store.createProject(project)
try await store.createAgentInstall(agent)
try await store.createSession(session)
let prefix =
    #"{"sessionId":"benchmark","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""#
let suffix = #""}}}"#
let payload = Data((prefix + String(repeating: "x", count: 1024 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
let batch = Array(repeating: NewEvent(kind: "acp.session/update", payload: payload), count: batchSize)
let clock = ContinuousClock()
let start = clock.now
let end = start.advanced(by: .seconds(2))
let eventLimit = 65_536  // At most 64 MiB of payload per process, removed before the next scenario.
var count = 0
var latencies: [Double] = []
var completionDelays: [Double] = []
while count + batchSize <= eventLimit {
    // Absolute deadlines preserve offered load when a commit takes longer than the arrival interval.
    let due = rate == 0 ? clock.now : start.advanced(by: .seconds(Double(count + batchSize) / Double(rate)))
    if due > end || clock.now >= end { break }
    if rate > 0 { try await clock.sleep(until: due) }
    let before = clock.now
    let stored = try await store.append(batch, to: session.id)
    let after = clock.now
    guard stored.count == batchSize, stored.first?.sequence == Int64(count + 1),
        stored.last?.sequence == Int64(count + batchSize)
    else { throw BenchmarkError.replayMismatch }
    count += batchSize
    latencies.append(seconds(before.duration(to: after)) * 1000)
    completionDelays.append(seconds(due.duration(to: after)) * 1000)
}
let elapsed = seconds(start.duration(to: clock.now))
// Verify persisted bytes and ordering outside the timed region, through the public replay API.
let reopened = try PersistenceStore(databaseURL: url)
var cursor: Int64 = 0
while true {
    let page = try await reopened.events(in: session.id, after: cursor)
    if page.isEmpty { break }
    for event in page {
        guard event.sequence == cursor + 1, event.event.payload == payload else { throw BenchmarkError.replayMismatch }
        cursor = event.sequence
    }
}
guard cursor == Int64(count), !latencies.isEmpty else { throw BenchmarkError.replayMismatch }
latencies.sort()
completionDelays.sort()
let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
let measurements: [String: Double] = [
    "batchSize": Double(batchSize), "offeredEventsPerSecond": Double(rate), "payloadBytes": Double(payload.count),
    "windowSeconds": 2, "elapsedSeconds": elapsed, "events": Double(count),
    "eventsPerSecond": Double(count) / elapsed,
    "scheduledEvents": rate == 0 ? 0 : Double((2 * rate / batchSize) * batchSize),
    "appendP50MS": percentile(latencies, 0.5), "appendP95MS": percentile(latencies, 0.95),
    "appendMaxMS": percentile(latencies, 1), "completionDelayP95MS": percentile(completionDelays, 0.95),
    "databaseBytes": Double(fileSize), "eventLimitReached": count == eventLimit ? 1 : 0,
]
let data = try JSONSerialization.data(withJSONObject: [
    "scenario": "\(batchSize):\(rate)", "measurements": measurements,
])
print("BENCHMARK_RESULT=" + String(decoding: data, as: UTF8.self))
