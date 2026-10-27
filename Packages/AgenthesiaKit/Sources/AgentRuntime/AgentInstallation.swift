public import Foundation

/// A validated, private installation. Paths are relative to its immutable version directory.
public struct AgentInstallation: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case binary(archive: URL, sha256: String?)
        case npm(
            package: String,
            version: String,
            toolchain: NodeRuntime.Toolchain,
            requirements: NodeRuntime.Requirements
        )
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case unsupportedDistribution, unsafeArchive, invalidExecutable, checksumMismatch
        case downloadFailed, downloadTooLarge, invalidPackage, npmFailed, operationInProgress
        case alreadyInstalled, installationInUse, unownedPath, invalidMetadata

        public var errorDescription: String? {
            switch self {
            case .unsupportedDistribution: "This agent distribution is not supported on this Mac."
            case .unsafeArchive: "The agent archive is invalid, unsafe or exceeds the extraction limit."
            case .invalidExecutable:
                "The agent command is missing, invalid or outside its installation. Select another distribution."
            case .checksumMismatch: "The agent archive does not match its declared SHA-256 checksum."
            case .downloadFailed: "The agent archive could not be downloaded securely. Try again."
            case .downloadTooLarge: "The agent archive exceeds the download limit."
            case .invalidPackage: "The npm package metadata or lockfile is invalid. Choose another version."
            case .npmFailed:
                "npm could not install the agent. Lifecycle scripts are disabled; check prerequisites or choose another distribution."
            case .operationInProgress: "Another installation or removal is in progress. Try again when it finishes."
            case .alreadyInstalled: "This agent version is already installed. The existing files were preserved."
            case .installationInUse: "This agent version is in use. End its sessions before removing it."
            case .unownedPath: "The installation path is not owned by Agenthesia. Its files were preserved."
            case .invalidMetadata: "The saved agent installation is invalid. Select or install another version."
            }
        }
    }

    public let id: UUID
    public let agentID: String
    public let name: String
    public let version: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let source: Source
    public let installedAt: Date

    public var toolchain: NodeRuntime.Toolchain? {
        if case .npm(_, _, let toolchain, _) = source { toolchain } else { nil }
    }
}
