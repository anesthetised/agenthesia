import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite(.timeLimit(.minutes(1)))
final class PersistenceStoreTests: Sendable {
    let directory: URL
    let databaseURL: URL
    let database: DatabaseQueue
    let store: PersistenceStore
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "agenthesia-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appending(path: "sessions.sqlite")
        database = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        // Pin page size so the storage-growth regression is independent of SQLite build defaults.
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA page_size = 4096") }
        store = try PersistenceStore(database: database)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func seed(at timestamp: Date? = nil) async throws -> (ProjectRecord, AgentInstallRecord, SessionRecord) {
        let date = timestamp ?? self.date
        let project = ProjectRecord(name: "Project ✓", rootPath: "/tmp/project's directory", createdAt: date)
        let agent = AgentInstallRecord(
            name: "Manual agent",
            executable: "/path with spaces/agent",
            arguments: ["--acp", "quote'\"", "✓"],
            createdAt: date
        )
        let session = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            agentSessionID: "remote-session",
            title: "Session ✓",
            workingDirectory: project.rootPath,
            createdAt: date
        )
        try await store.createProject(project)
        try await store.createAgentInstall(agent)
        try await store.createSession(session)
        return (project, agent, session)
    }

    private func event(_ value: Int = 0) -> NewEvent {
        NewEvent(kind: "user_prompt", payload: Data("{\"value\":\(value)}".utf8), timestamp: date)
    }

    @Test func persistsRecordsAndOriginalPayloadAcrossReopen() async throws {
        #expect(try await store.projects().isEmpty)
        #expect(try await store.agentInstalls().isEmpty)
        let (project, agent, session) = try await seed()
        let payload = Data(
            """
            { "sessionId": "remote-session", "update": {
              "sessionUpdate": "agent_message_chunk", "content": {"type":"text","text":"Hello ✓"},
              "future_field": [null, true, {"precise": 9007199254740993}]
            }, "_meta": {"vendor.extension": "preserve me"} }
            """.utf8
        )
        let raw = NewEvent(kind: "acp.session/update", payload: payload, timestamp: date)
        let appended = try await store.append([raw], to: session.id)

        let reopened = try PersistenceStore(databaseURL: databaseURL)
        #expect(try await reopened.projects() == [project])
        #expect(try await reopened.agentInstalls() == [agent])
        #expect(try await reopened.session(id: session.id) == session)
        #expect(try await reopened.sessions(in: project.id) == [session])
        #expect(try await reopened.events(in: session.id) == appended)
        #expect(try await reopened.events(in: session.id).first?.event.payload == payload)
        #expect(try await database.read { try Schema.migrator.appliedMigrations($0) } == ["v1"])
    }

    @Test(arguments: [Date(timeIntervalSinceReferenceDate: 800_000_000.0.nextUp), Date()])
    func fractionalDatesRoundTripExactly(timestamp: Date) async throws {
        let (project, agent, session) = try await seed(at: timestamp)
        let raw = NewEvent(kind: "date", payload: Data("{}".utf8), timestamp: timestamp)
        let appended = try await store.append([raw], to: session.id)
        let reopened = try PersistenceStore(databaseURL: databaseURL)
        #expect(try await reopened.projects() == [project])
        #expect(try await reopened.agentInstalls() == [agent])
        #expect(try await reopened.session(id: session.id) == session)
        #expect(try await reopened.sessions(in: project.id) == [session])
        #expect(try await reopened.events(in: session.id) == appended)
    }

    @Test func readsIndependentSessionsInSequenceOrderWithPagination() async throws {
        let (project, agent, first) = try await seed()
        let second = SessionRecord(
            projectID: project.id,
            agentInstallID: agent.id,
            workingDirectory: "/tmp/worktree",
            createdAt: date.addingTimeInterval(1)
        )
        try await store.createSession(second)
        #expect(try await store.session(id: second.id) == second)
        #expect(try await store.sessions(in: project.id) == [first, second])
        let unknown = NewEvent(
            kind: "future.event",
            formatVersion: 99,
            payload: Data("[1,null]".utf8),
            timestamp: .distantPast
        )
        let batch = try await store.append([event(1), unknown, event(3)], to: first.id)
        #expect(batch.map(\.sequence) == [1, 2, 3])
        #expect(try await store.append([event(4)], to: second.id).map(\.sequence) == [1])
        #expect(try await store.events(in: first.id, limit: 2) == Array(batch.prefix(2)))
        #expect(try await store.events(in: first.id, after: 2, limit: 2) == Array(batch.suffix(1)))
        #expect(try await store.events(in: first.id, after: 3).isEmpty)
        #expect(try await store.events(in: second.id).count == 1)
        #expect(try await store.events(in: UUID()).isEmpty)
        #expect(try await store.sessions(in: UUID()).isEmpty)
        #expect(try await store.session(id: UUID()) == nil)
        #expect(try await store.append([], to: first.id).isEmpty)
    }

    @Test func oneKiBPayloadsDoNotAllocateAnOverflowPagePerEvent() async throws {
        let (_, _, session) = try await seed()
        let pagesBefore = try #require(await database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") })
        let payload = Data(("\"" + String(repeating: "x", count: 1022) + "\"").utf8)
        let batch = Array(repeating: NewEvent(kind: "acp.session/update", payload: payload), count: 256)
        _ = try await store.append(batch, to: session.id)
        let pagesAfter = try #require(await database.read { try Int.fetchOne($0, sql: "PRAGMA page_count") })
        // Include the primary-key index and table growth, with room for partially filled pages.
        #expect((pagesAfter - pagesBefore) * 4096 < batch.count * 2048)
    }

    @Test func concurrentBatchesAreAtomicAndGetUniqueSequences() async throws {
        let (_, _, session) = try await seed()
        let batches = try await withThrowingTaskGroup(of: [StoredEvent].self) { group in
            for index in 0..<20 {
                group.addTask { try await self.store.append([self.event(index), self.event(index)], to: session.id) }
            }
            var batches: [[StoredEvent]] = []
            for try await batch in group { batches.append(batch) }
            return batches
        }
        for batch in batches {
            #expect(batch.count == 2)
            #expect(batch[1].sequence == batch[0].sequence + 1)
        }
        let events = try await store.events(in: session.id)
        #expect(events.map(\.sequence) == Array(Int64(1)...40))
        #expect(events == batches.flatMap { $0 }.sorted { $0.sequence < $1.sequence })
    }

    @Test(arguments: ["json", "kind", "version", "nul", "utf8"])
    func failedBatchRollsBackAndDoesNotConsumeSequences(invalidField: String) async throws {
        let (_, _, session) = try await seed()
        let initial = try await store.append([event()], to: session.id)
        let payload: Data
        switch invalidField {
        case "json": payload = Data("{invalid".utf8)
        case "nul": payload = Data("{}\0garbage".utf8)
        case "utf8": payload = Data(#"{"a":""#.utf8) + Data([0xFF, 0xFE]) + Data(#""}"#.utf8)
        default: payload = Data("{}".utf8)
        }
        let invalid = NewEvent(
            kind: invalidField == "kind" ? " " : "error",
            formatVersion: invalidField == "version" ? 0 : 1,
            payload: payload
        )
        if invalidField == "nul" || invalidField == "utf8" {
            await #expect(throws: PersistenceError.invalidEventPayload) {
                try await store.append([event(1), invalid, event(2)], to: session.id)
            }
        } else {
            await #expect(throws: DatabaseError.self) {
                try await store.append([event(1), invalid, event(2)], to: session.id)
            }
        }
        #expect(try await store.events(in: session.id) == initial)
        #expect(try await store.append([event(3)], to: session.id).map(\.sequence) == [2])
    }

    @Test(arguments: [#""\u0000""#, #"{"text":"é🙂"}"#])
    func validUTF8AndEscapedNULRemainUnchanged(json: String) async throws {
        let (_, _, session) = try await seed()
        let raw = NewEvent(kind: "json", payload: Data(json.utf8))
        let appended = try await store.append([raw], to: session.id)
        #expect(try await store.events(in: session.id) == appended)
        #expect(appended.first?.event.payload == Data(json.utf8))
    }

    @Test func rejectsMissingParentsAndDuplicateMetadata() async throws {
        let (project, agent, session) = try await seed()
        await #expect(throws: DatabaseError.self) { try await store.createProject(project) }
        await #expect(throws: DatabaseError.self) {
            try await store.createProject(ProjectRecord(name: "Duplicate root", rootPath: project.rootPath))
        }
        await #expect(throws: DatabaseError.self) { try await store.createAgentInstall(agent) }
        await #expect(throws: DatabaseError.self) { try await store.createSession(session) }
        await #expect(throws: DatabaseError.self) {
            try await store.createSession(
                SessionRecord(projectID: UUID(), agentInstallID: agent.id, workingDirectory: "/tmp")
            )
        }
        await #expect(throws: DatabaseError.self) {
            try await store.createSession(
                SessionRecord(projectID: project.id, agentInstallID: UUID(), workingDirectory: "/tmp")
            )
        }
        await #expect(throws: DatabaseError.self) { try await store.append([event()], to: UUID()) }
        #expect(try await store.sessions(in: project.id) == [session])
    }

    @Test func databaseRejectsEventMutationAndParentDeletion() async throws {
        let (_, _, session) = try await seed()
        let initial = try await store.append([event()], to: session.id)
        for sql in [
            "UPDATE event SET payload = CAST('{}' AS BLOB)",
            "INSERT OR REPLACE INTO event SELECT sessionID, sequence, kind, formatVersion, CAST('{}' AS BLOB), timestamp FROM event",
            "INSERT OR REPLACE INTO event (rowid, sessionID, sequence, kind, formatVersion, payload, timestamp) "
                + "SELECT rowid, sessionID, sequence + 1, kind, formatVersion, payload, timestamp FROM event",
            "DELETE FROM event",
            "DELETE FROM session",
            "DELETE FROM project",
            "DELETE FROM agent_install",
        ] {
            await #expect(throws: DatabaseError.self) { try await database.write { try $0.execute(sql: sql) } }
        }
        #expect(try await store.events(in: session.id) == initial)
    }

    @Test func cancellationDoesNotWriteEvents() async throws {
        let (_, _, session) = try await seed()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.append([event()], to: session.id)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.events(in: session.id).isEmpty)
        #expect(try await store.append([event()], to: session.id).map(\.sequence) == [1])
    }

    @Test func rejectsNewerSchemaWithoutChangingHistory() async throws {
        let (_, _, session) = try await seed()
        let original = try await store.append([event()], to: session.id)
        try await database.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('future-version')") }
        #expect(throws: PersistenceError.newerSchema) { try PersistenceStore(databaseURL: databaseURL) }
        #expect(try await store.events(in: session.id) == original)
        #expect(try await database.read { try Schema.migrator.appliedIdentifiers($0) } == ["v1", "future-version"])
    }

    @Test func failedMigrationRollsBackWithoutErasingExistingData() throws {
        let existing = try DatabaseQueue()
        try existing.write { db in
            try db.execute(sql: "CREATE TABLE agent_install (value TEXT); INSERT INTO agent_install VALUES ('keep')")
        }
        #expect(throws: DatabaseError.self) { try PersistenceStore(database: existing) }
        try existing.read { (db: Database) throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT value FROM agent_install") == "keep")
            #expect(try !db.tableExists("project"))
            #expect(try !db.tableExists("session"))
            #expect(try !db.tableExists("event"))
            #expect(try Schema.migrator.appliedIdentifiers(db).isEmpty)
        }
    }

    @Test func rejectsInvalidPagesAndDatabaseLocations() async throws {
        for limit in [-1, 0, 10_001] {
            await #expect(throws: PersistenceError.invalidEventPage) {
                try await store.events(in: UUID(), limit: limit)
            }
        }
        await #expect(throws: PersistenceError.invalidEventPage) { try await store.events(in: UUID(), after: -1) }
        let remote = try #require(URL(string: "https://example.com/database.sqlite"))
        #expect(throws: PersistenceError.invalidDatabaseURL) { try PersistenceStore(databaseURL: remote) }
        #expect(throws: DatabaseError.self) {
            try PersistenceStore(databaseURL: directory.appending(path: "missing/database.sqlite"))
        }
    }

    @Test func exhaustedSequenceFailsWithoutOverflow() async throws {
        let (_, _, session) = try await seed()
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO event (sessionID, sequence, kind, formatVersion, payload, timestamp)
                    VALUES (?, ?, 'user_prompt', 1, ?, 0)
                    """,
                arguments: [session.id.uuidString, Int64.max, Data("{}".utf8)]
            )
        }
        await #expect(throws: PersistenceError.sequenceExhausted) { try await store.append([event()], to: session.id) }
        #expect(try await store.events(in: session.id).map(\.sequence) == [Int64.max])
    }
}
