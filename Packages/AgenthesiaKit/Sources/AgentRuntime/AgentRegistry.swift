public import Foundation

/// Metadata from the stable ACP Registry. Inspecting it never launches or installs an agent.
public enum AgentRegistry {
    static let maximumBytes = 1_048_576

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case invalidCatalog
        case unsupportedVersion(String)
        case responseTooLarge
        case invalidResponse
        case httpStatus(Int)
        case notModifiedWithoutCache
        case networkUnavailable
        case cacheUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidCatalog: "The agent registry contains invalid metadata."
            case .unsupportedVersion: "The agent registry uses an unsupported format version."
            case .responseTooLarge: "The agent registry exceeds the size limit."
            case .invalidResponse: "The agent registry returned an invalid response."
            case .httpStatus(let status): "The agent registry returned HTTP \(status)."
            case .notModifiedWithoutCache: "The agent registry returned no data and no usable cache is available."
            case .networkUnavailable: "The agent registry could not be reached."
            case .cacheUnavailable: "The agent registry was loaded, but its local cache could not be saved."
            }
        }
    }

    public enum Platform: String, Sendable {
        case macOSArm64 = "darwin-aarch64"
        case macOSIntel = "darwin-x86_64"

        public static var current: Self {
            #if arch(arm64)
                .macOSArm64
            #else
                .macOSIntel
            #endif
        }
    }

    public enum Installation: Equatable, Sendable {
        case binary(Binary)
        case npm(Package)
        case unsupported(UnsupportedReason)
    }

    public enum UnsupportedReason: Equatable, Sendable {
        case uvx
        case noCompatibleDistribution
    }

    public struct Catalog: Sendable {
        public let version: String
        public let agents: [Agent]

        /// Unknown fields and distribution kinds are tolerated; invalid known metadata rejects the response.
        public init(data: Data) throws {
            guard data.count <= maximumBytes else { throw Failure.responseTooLarge }
            do {
                let decoded = try JSONDecoder().decode(Envelope.self, from: data)
                guard matches(decoded.version, #"[0-9]+\.[0-9]+\.[0-9]+"#) else {
                    throw Failure.invalidCatalog
                }
                guard decoded.version.hasPrefix("1.") else { throw Failure.unsupportedVersion(decoded.version) }
                guard decoded.agents.count <= 512,
                    Set(decoded.agents.map(\.id)).count == decoded.agents.count
                else { throw Failure.invalidCatalog }
                version = decoded.version
                agents = decoded.agents
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.invalidCatalog
            }
        }

        private struct Envelope: Decodable {
            let version: String
            let agents: [Agent]
        }
    }

    public struct Agent: Decodable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let description: String
        public let repository: URL?
        public let website: URL?
        public let authors: [String]
        public let license: String?
        public let licenseURL: URL?
        public let icon: URL?
        public let distribution: Distributions

        private enum CodingKeys: String, CodingKey {
            case id, name, version, description, repository, website, authors, license, icon, distribution
            case licenseURL = "license_url"
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            version = try values.decode(String.self, forKey: .version)
            description = try values.decode(String.self, forKey: .description)
            repository = try values.decodeIfPresent(URL.self, forKey: .repository)
            website = try values.decodeIfPresent(URL.self, forKey: .website)
            authors = try values.decodeIfPresent([String].self, forKey: .authors) ?? []
            license = try values.decodeIfPresent(String.self, forKey: .license)
            licenseURL = try values.decodeIfPresent(URL.self, forKey: .licenseURL)
            icon = try values.decodeIfPresent(URL.self, forKey: .icon)
            distribution = try values.decode(Distributions.self, forKey: .distribution)
            guard id.count <= 128, matches(id, "[a-z][a-z0-9-]*"),
                version.count <= 128, matches(version, "[a-zA-Z0-9][a-zA-Z0-9._+-]*"),
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !description.isEmpty,
                [repository, website, licenseURL, icon].compactMap({ $0 }).allSatisfy({ safeURL($0) })
            else { throw Failure.invalidCatalog }
        }

        public func installation(for platform: Platform = .current) -> Installation {
            if let binary = distribution.binary[platform.rawValue] { return .binary(binary) }
            if let npm = distribution.npx { return .npm(npm) }
            if distribution.uvx != nil { return .unsupported(.uvx) }
            return .unsupported(.noCompatibleDistribution)
        }
    }

    public struct Distributions: Decodable, Sendable {
        public let binary: [String: Binary]
        public let npx: Package?
        public let uvx: Package?
        public let unsupportedKinds: [String]

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            binary = try values.decodeIfPresent([String: Binary].self, forKey: Key("binary")) ?? [:]
            npx = try values.decodeIfPresent(Package.self, forKey: Key("npx"))
            uvx = try values.decodeIfPresent(Package.self, forKey: Key("uvx"))
            unsupportedKinds = values.allKeys.map(\.stringValue).filter {
                !["binary", "npx", "uvx"].contains($0)
            }.sorted()
            guard !values.allKeys.isEmpty else { throw Failure.invalidCatalog }
            if let npx {
                // The schema permits an unversioned name. The installer must pin it to the entry's version.
                let name = #"(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*"#
                let version = #"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?(?:\+[a-zA-Z0-9.-]+)?"#
                guard matches(npx.package, "\(name)(?:@\(version))?") else { throw Failure.invalidCatalog }
            }
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { return nil }
        }
    }

    public struct Binary: Decodable, Equatable, Sendable {
        public let archive: URL
        public let command: String
        public let arguments: [String]
        public let environment: [String: String]
        public let sha256: String?

        private enum CodingKeys: String, CodingKey { case archive, cmd, sha256 }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            archive = try values.decode(URL.self, forKey: .archive)
            command = try values.decode(String.self, forKey: .cmd)
            sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
            let launch = try Launch(from: decoder)
            arguments = launch.arguments
            environment = launch.environment
            let path = command.replacingOccurrences(of: "\\", with: "/")
            guard safeURL(archive, httpsOnly: true), !path.isEmpty, !path.hasPrefix("/"),
                !path.contains(":"), !path.contains("\0"),
                !path.split(separator: "/").contains(".."),
                path.split(separator: "/").contains(where: { $0 != "." }),
                sha256.map({ matches($0, "[a-fA-F0-9]{64}") }) ?? true
            else { throw Failure.invalidCatalog }
        }
    }

    public struct Package: Decodable, Equatable, Sendable {
        /// Registry package reference, not a shell command; installation must use an exact version.
        public let package: String
        public let arguments: [String]
        public let environment: [String: String]

        private enum CodingKeys: String, CodingKey { case package }

        public init(from decoder: any Decoder) throws {
            package = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .package)
            let launch = try Launch(from: decoder)
            arguments = launch.arguments
            environment = launch.environment
            guard !package.isEmpty, package.count <= 256, !package.contains("\0") else {
                throw Failure.invalidCatalog
            }
        }
    }

    private struct Launch: Decodable {
        let arguments: [String]
        let environment: [String: String]

        private enum CodingKeys: String, CodingKey { case args, env }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            arguments = try values.decodeIfPresent([String].self, forKey: .args) ?? []
            environment = try values.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            guard arguments.allSatisfy({ !$0.contains("\0") }),
                environment.allSatisfy({ key, value in
                    !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
                })
            else { throw Failure.invalidCatalog }
        }
    }

    static func safeURL(_ url: URL, httpsOnly: Bool = false) -> Bool {
        (url.scheme == "https" || (!httpsOnly && url.scheme == "http"))
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
}
