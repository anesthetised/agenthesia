import GRDB

enum Schema {
    // UUIDs use uppercase uuidString TEXT; bind uuidString, not GRDB's default UUID BLOB.
    // Date columns store REAL seconds since 2001-01-01 (Foundation's reference date), without epoch conversion.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE project (
                        id TEXT NOT NULL PRIMARY KEY,
                        name TEXT NOT NULL,
                        rootPath TEXT NOT NULL UNIQUE,
                        createdAt REAL NOT NULL
                    );
                    CREATE TABLE agent_install (
                        id TEXT NOT NULL PRIMARY KEY,
                        name TEXT NOT NULL,
                        executable TEXT NOT NULL,
                        arguments BLOB NOT NULL,
                        createdAt REAL NOT NULL
                    );
                    CREATE TABLE session (
                        id TEXT NOT NULL PRIMARY KEY,
                        projectID TEXT NOT NULL REFERENCES project(id) ON DELETE RESTRICT,
                        agentInstallID TEXT NOT NULL REFERENCES agent_install(id) ON DELETE RESTRICT,
                        agentSessionID TEXT,
                        protocolVersion INTEGER NOT NULL CHECK (protocolVersion > 0),
                        title TEXT,
                        workingDirectory TEXT NOT NULL,
                        createdAt REAL NOT NULL
                    );
                    CREATE INDEX session_project ON session(projectID, createdAt, id);
                    CREATE INDEX session_agent_install ON session(agentInstallID);
                    CREATE TABLE event (
                        sessionID TEXT NOT NULL REFERENCES session(id) ON DELETE RESTRICT,
                        sequence INTEGER NOT NULL CHECK (typeof(sequence) = 'integer' AND sequence > 0),
                        kind TEXT NOT NULL CHECK (length(trim(kind)) > 0),
                        formatVersion INTEGER NOT NULL CHECK (formatVersion > 0),
                        payload BLOB NOT NULL CHECK (typeof(payload) = 'blob' AND json_valid(CAST(payload AS TEXT))),
                        timestamp REAL NOT NULL,
                        PRIMARY KEY (sessionID, sequence)
                    );
                    CREATE TRIGGER event_no_replace BEFORE INSERT ON event
                    WHEN EXISTS (SELECT 1 FROM event WHERE sessionID = NEW.sessionID AND sequence = NEW.sequence)
                    BEGIN
                        SELECT RAISE(ABORT, 'Events are append-only');
                    END;
                    CREATE TRIGGER event_no_update BEFORE UPDATE ON event
                    BEGIN
                        SELECT RAISE(ABORT, 'Events are append-only');
                    END;
                    CREATE TRIGGER event_no_delete BEFORE DELETE ON event
                    BEGIN
                        SELECT RAISE(ABORT, 'Events are append-only');
                    END;
                    """
            )
        }
        return migrator
    }
}
