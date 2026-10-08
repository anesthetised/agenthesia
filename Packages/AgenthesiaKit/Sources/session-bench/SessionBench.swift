import AgenthesiaCore
import Foundation
import Persistence

/// Measures reduction and value publication only; fixture creation and SQLite I/O are outside the timing.
@main struct SessionBench {
    struct Sample: Encodable {
        let run: Int
        let events: Int
        let publishEvery: Int
        let publications: Int
        let milliseconds: Double
        let characters: Int
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-bench-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceStore(databaseURL: directory.appending(path: "events.sqlite"))
        let project = ProjectRecord(name: "Benchmark", rootPath: "/benchmark")
        let agent = AgentInstallRecord(name: "Fixture", executable: "unused")
        let session = SessionRecord(projectID: project.id, agentInstallID: agent.id, workingDirectory: "/benchmark")
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(session)
        let raw = Data(
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello world. "}}}}"#
                .utf8
        )
        let events = try await store.append(
            Array(repeating: NewEvent(kind: "acp.session/update", payload: raw), count: 10_000),
            to: session.id
        )
        var samples: [Sample] = []
        for run in 1...3 {
            for cadence in [1, 16] {
                var reduced = TranscriptState()
                var published = TranscriptState()
                var publications = 0
                let start = ContinuousClock.now
                for (index, event) in events.enumerated() {
                    try reduced.apply(event)
                    if (index + 1).isMultiple(of: cadence) || index == events.count - 1 {
                        published = reduced
                        publications += 1
                    }
                    // Retain the published snapshot across mutations, as Observation consumers do.
                    withExtendedLifetime(published) {}
                }
                let elapsed = start.duration(to: .now).components
                let characters = published.items.first?.message?.text.count ?? 0
                precondition(characters == 130_000 && published.sequence == 10_000)
                samples.append(
                    Sample(
                        run: run,
                        events: events.count,
                        publishEvery: cadence,
                        publications: publications,
                        milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                        characters: characters
                    )
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(samples), as: UTF8.self))
    }
}
