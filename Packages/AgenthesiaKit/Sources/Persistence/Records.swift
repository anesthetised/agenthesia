public import Foundation

public struct ProjectRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, rootPath: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}

/// A manually configured agent command. Registry installation metadata comes with the installers.
public struct AgentInstallRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        executable: String,
        arguments: [String] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.createdAt = createdAt
    }
}

public struct SessionRecord: Identifiable, Equatable, Sendable {
    /// App identity, independent of the agent's session identifier.
    public let id: UUID
    public let projectID: UUID
    public let agentInstallID: UUID
    public let agentSessionID: String?
    public let protocolVersion: Int
    public let title: String?
    public let workingDirectory: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        agentInstallID: UUID,
        agentSessionID: String? = nil,
        protocolVersion: Int = 1,
        title: String? = nil,
        workingDirectory: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.agentInstallID = agentInstallID
        self.agentSessionID = agentSessionID
        self.protocolVersion = protocolVersion
        self.title = title
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
    }
}

/// An opaque JSON payload. The caller defines event kinds and their versioned schemas.
public struct NewEvent: Equatable, Sendable {
    public let kind: String
    public let formatVersion: Int
    public let payload: Data
    public let timestamp: Date

    public init(kind: String, formatVersion: Int = 1, payload: Data, timestamp: Date = .now) {
        self.kind = kind
        self.formatVersion = formatVersion
        self.payload = payload
        self.timestamp = timestamp
    }
}

public struct StoredEvent: Equatable, Sendable {
    public let sessionID: UUID
    /// Monotonically increasing within a session, starting at one. Use this, not timestamps, for replay.
    public let sequence: Int64
    public let event: NewEvent
}
