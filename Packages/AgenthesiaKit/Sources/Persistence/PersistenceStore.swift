public import Foundation
import GRDB

public enum PersistenceError: Error, Equatable {
    case invalidDatabaseURL
    case newerSchema
    case invalidEventPayload
    case invalidEventPage
    case sequenceExhausted
}

/// Serializes database access through GRDB. Async operations do not block the caller's actor.
public final class PersistenceStore: Sendable {
    private let database: DatabaseQueue

    /// Opens or creates a database and migrates it. The parent directory must already exist.
    /// Opening and migration are synchronous; call this away from the main actor.
    public convenience init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw PersistenceError.invalidDatabaseURL }
        try self.init(database: DatabaseQueue(path: databaseURL.path(percentEncoded: false)))
    }

    init(database: DatabaseQueue) throws {
        // REPLACE must fire the delete guard even when the conflict is on the hidden rowid.
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA recursive_triggers = ON") }
        let migrator = Schema.migrator
        guard try !database.read(migrator.hasBeenSuperseded) else { throw PersistenceError.newerSchema }
        try migrator.migrate(database)
        self.database = database
    }

    public func createProject(_ project: ProjectRecord) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO project (id, name, rootPath, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [
                    project.id.uuidString, project.name, project.rootPath,
                    project.createdAt.timeIntervalSinceReferenceDate,
                ]
            )
        }
    }

    public func projects() async throws -> [ProjectRecord] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM project ORDER BY createdAt, id").map { row in
                try ProjectRecord(
                    id: row.decode(forColumn: "id"),
                    name: row.decode(forColumn: "name"),
                    rootPath: row.decode(forColumn: "rootPath"),
                    createdAt: Date(timeIntervalSinceReferenceDate: row.decode(forColumn: "createdAt"))
                )
            }
        }
    }

    public func createAgentInstall(_ agent: AgentInstallRecord) async throws {
        let arguments = try JSONEncoder().encode(agent.arguments)
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent_install (id, name, executable, arguments, installationID, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    agent.id.uuidString, agent.name, agent.executable, arguments, agent.installationID?.uuidString,
                    agent.createdAt.timeIntervalSinceReferenceDate,
                ]
            )
        }
    }

    public func agentInstalls() async throws -> [AgentInstallRecord] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_install ORDER BY createdAt, id").map { row in
                try AgentInstallRecord(
                    id: row.decode(forColumn: "id"),
                    name: row.decode(forColumn: "name"),
                    executable: row.decode(forColumn: "executable"),
                    arguments: JSONDecoder().decode([String].self, from: row.decode(forColumn: "arguments")),
                    installationID: row.decode(forColumn: "installationID"),
                    createdAt: Date(timeIntervalSinceReferenceDate: row.decode(forColumn: "createdAt"))
                )
            }
        }
    }

    public func createSession(_ session: SessionRecord) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session
                    (id, projectID, agentInstallID, agentSessionID, protocolVersion, title, workingDirectory, baseRevision, baseBranch, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    session.id.uuidString, session.projectID.uuidString, session.agentInstallID.uuidString,
                    session.agentSessionID, session.protocolVersion, session.title, session.workingDirectory,
                    session.baseRevision, session.baseBranch,
                    session.createdAt.timeIntervalSinceReferenceDate,
                ]
            )
        }
    }

    /// A session's title may be set after creation: from the agent or from the first prompt.
    public func updateTitle(_ title: String, of sessionID: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE session SET title = ? WHERE id = ?",
                arguments: [title, sessionID.uuidString]
            )
        }
    }

    public func session(id: UUID) async throws -> SessionRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM session WHERE id = ?", arguments: [id.uuidString])
                .map(Self.decodeSession)
        }
    }

    public func sessions(in projectID: UUID) async throws -> [SessionRecord] {
        try await database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM session WHERE projectID = ? ORDER BY createdAt, id",
                arguments: [projectID.uuidString]
            ).map(Self.decodeSession)
        }
    }

    /// Commits the whole batch or none of it, preserving input order. Empty batches are a no-op.
    /// Callers must await appends in arrival order; concurrently submitted batches have no arrival ordering guarantee.
    public func append(_ events: [NewEvent], to sessionID: UUID) async throws -> [StoredEvent] {
        guard !events.isEmpty else { return [] }
        return try await database.write { db in
            let last =
                try Int64.fetchOne(
                    db,
                    sql: "SELECT MAX(sequence) FROM event WHERE sessionID = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
            guard last <= Int64.max - Int64(events.count) else { throw PersistenceError.sequenceExhausted }
            var stored: [StoredEvent] = []
            for (index, event) in events.enumerated() {
                // SQLite JSON validation accepts invalid UTF-8 and ignores bytes after a raw NUL.
                guard !event.payload.contains(0), String(validating: event.payload, as: UTF8.self) != nil else {
                    throw PersistenceError.invalidEventPayload
                }
                let sequence = last + Int64(index) + 1
                try db.execute(
                    sql: """
                        INSERT INTO event (sessionID, sequence, kind, formatVersion, payload, timestamp)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        sessionID.uuidString, sequence, event.kind, event.formatVersion, event.payload,
                        event.timestamp.timeIntervalSinceReferenceDate,
                    ]
                )
                stored.append(StoredEvent(sessionID: sessionID, sequence: sequence, event: event))
            }
            return stored
        }
    }

    /// Reads a bounded page in replay order. Unknown kinds and versions remain available as raw data.
    public func events(in sessionID: UUID, after sequence: Int64 = 0, limit: Int = 500) async throws -> [StoredEvent] {
        guard sequence >= 0, (1...10_000).contains(limit) else { throw PersistenceError.invalidEventPage }
        return try await database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM event WHERE sessionID = ? AND sequence > ? ORDER BY sequence LIMIT ?",
                arguments: [sessionID.uuidString, sequence, limit]
            ).map(Self.decodeEvent)
        }
    }

    /// Each session's most recent event, one index lookup per session.
    public func lastEvents() async throws -> [UUID: StoredEvent] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT event.* FROM session JOIN event ON event.sessionID = session.id
                    AND event.sequence = (SELECT MAX(sequence) FROM event WHERE sessionID = session.id)
                    """
            )
            return try Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    let event = try Self.decodeEvent(row)
                    return (event.sessionID, event)
                }
            )
        }
    }

    private static func decodeEvent(_ row: Row) throws -> StoredEvent {
        try StoredEvent(
            sessionID: row.decode(forColumn: "sessionID"),
            sequence: row.decode(forColumn: "sequence"),
            event: NewEvent(
                kind: row.decode(forColumn: "kind"),
                formatVersion: row.decode(forColumn: "formatVersion"),
                payload: row.decode(forColumn: "payload"),
                timestamp: Date(timeIntervalSinceReferenceDate: row.decode(forColumn: "timestamp"))
            )
        )
    }

    private static func decodeSession(_ row: Row) throws -> SessionRecord {
        try SessionRecord(
            id: row.decode(forColumn: "id"),
            projectID: row.decode(forColumn: "projectID"),
            agentInstallID: row.decode(forColumn: "agentInstallID"),
            agentSessionID: row.decode(forColumn: "agentSessionID"),
            protocolVersion: row.decode(forColumn: "protocolVersion"),
            title: row.decode(forColumn: "title"),
            workingDirectory: row.decode(forColumn: "workingDirectory"),
            baseRevision: row.decode(forColumn: "baseRevision"),
            baseBranch: row.decode(forColumn: "baseBranch"),
            createdAt: Date(timeIntervalSinceReferenceDate: row.decode(forColumn: "createdAt"))
        )
    }
}
