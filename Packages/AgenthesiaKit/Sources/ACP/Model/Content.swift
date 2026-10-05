public import JSONRPC

extension ACP {
    public enum Role: OpenEnum {
        case assistant
        case user
        case unknown(String)

        public static let knownCases: [Role] = [.assistant, .user]

        public var rawValue: String {
            switch self {
            case .assistant: "assistant"
            case .user: "user"
            case .unknown(let value): value
            }
        }
    }

    public struct Annotations: Codable, Hashable, Sendable {
        public var audience: [Role]?
        public var lastModified: String?
        public var priority: Double?
        public var meta: Meta?

        public init(audience: [Role]? = nil, lastModified: String? = nil, priority: Double? = nil, meta: Meta? = nil) {
            self.audience = audience
            self.lastModified = lastModified
            self.priority = priority
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case audience, lastModified, priority
            case meta = "_meta"
        }
    }

    public struct TextContent: Codable, Hashable, Sendable {
        public var text: String
        public var annotations: Annotations?
        public var meta: Meta?

        public init(text: String, annotations: Annotations? = nil, meta: Meta? = nil) {
            self.text = text
            self.annotations = annotations
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case text, annotations
            case meta = "_meta"
        }
    }

    public struct ImageContent: Codable, Hashable, Sendable {
        /// Base64-encoded image data.
        public var data: String
        public var mimeType: String
        public var uri: String?
        public var annotations: Annotations?
        public var meta: Meta?

        public init(
            data: String,
            mimeType: String,
            uri: String? = nil,
            annotations: Annotations? = nil,
            meta: Meta? = nil
        ) {
            self.data = data
            self.mimeType = mimeType
            self.uri = uri
            self.annotations = annotations
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case data, mimeType, uri, annotations
            case meta = "_meta"
        }
    }

    public struct AudioContent: Codable, Hashable, Sendable {
        /// Base64-encoded audio data.
        public var data: String
        public var mimeType: String
        public var annotations: Annotations?
        public var meta: Meta?

        public init(data: String, mimeType: String, annotations: Annotations? = nil, meta: Meta? = nil) {
            self.data = data
            self.mimeType = mimeType
            self.annotations = annotations
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case data, mimeType, annotations
            case meta = "_meta"
        }
    }

    public struct ResourceLink: Codable, Hashable, Sendable {
        public var uri: String
        public var name: String
        public var title: String?
        public var description: String?
        public var mimeType: String?
        public var size: Int?
        public var annotations: Annotations?
        public var meta: Meta?

        public init(
            uri: String,
            name: String,
            title: String? = nil,
            description: String? = nil,
            mimeType: String? = nil,
            size: Int? = nil,
            annotations: Annotations? = nil,
            meta: Meta? = nil
        ) {
            self.uri = uri
            self.name = name
            self.title = title
            self.description = description
            self.mimeType = mimeType
            self.size = size
            self.annotations = annotations
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case uri, name, title, description, mimeType, size, annotations
            case meta = "_meta"
        }
    }

    public struct TextResourceContents: Codable, Hashable, Sendable {
        public var uri: String
        public var text: String
        public var mimeType: String?
        public var meta: Meta?

        public init(uri: String, text: String, mimeType: String? = nil, meta: Meta? = nil) {
            self.uri = uri
            self.text = text
            self.mimeType = mimeType
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case uri, text, mimeType
            case meta = "_meta"
        }
    }

    public struct BlobResourceContents: Codable, Hashable, Sendable {
        public var uri: String
        /// Base64-encoded contents.
        public var blob: String
        public var mimeType: String?
        public var meta: Meta?

        public init(uri: String, blob: String, mimeType: String? = nil, meta: Meta? = nil) {
            self.uri = uri
            self.blob = blob
            self.mimeType = mimeType
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case uri, blob, mimeType
            case meta = "_meta"
        }
    }

    /// The contents of an embedded resource: text or binary.
    public enum ResourceContents: Codable, Hashable, Sendable {
        case text(TextResourceContents)
        case blob(BlobResourceContents)
        case unknown(JSONValue)

        public init(from decoder: any Decoder) throws {
            if Tagged.has("text", in: decoder) {
                self = .text(try TextResourceContents(from: decoder))
            } else if Tagged.has("blob", in: decoder) {
                self = .blob(try BlobResourceContents(from: decoder))
            } else {
                self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .text(let contents): try contents.encode(to: encoder)
            case .blob(let contents): try contents.encode(to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }

    public struct EmbeddedResource: Codable, Hashable, Sendable {
        public var resource: ResourceContents
        public var annotations: Annotations?
        public var meta: Meta?

        public init(resource: ResourceContents, annotations: Annotations? = nil, meta: Meta? = nil) {
            self.resource = resource
            self.annotations = annotations
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case resource, annotations
            case meta = "_meta"
        }
    }

    /// A piece of content in a prompt, a message or a tool call.
    public enum ContentBlock: Codable, Hashable, Sendable {
        case text(TextContent)
        case image(ImageContent)
        case audio(AudioContent)
        case resourceLink(ResourceLink)
        case resource(EmbeddedResource)
        case unknown(JSONValue)

        /// A plain text block.
        public init(text: String) {
            self = .text(TextContent(text: text))
        }

        public init(from decoder: any Decoder) throws {
            switch try Tagged.tag(in: decoder, key: "type") {
            case "text": self = .text(try TextContent(from: decoder))
            case "image": self = .image(try ImageContent(from: decoder))
            case "audio": self = .audio(try AudioContent(from: decoder))
            case "resource_link": self = .resourceLink(try ResourceLink(from: decoder))
            case "resource": self = .resource(try EmbeddedResource(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .text(let content): try Tagged.encode(content, tag: "text", key: "type", to: encoder)
            case .image(let content): try Tagged.encode(content, tag: "image", key: "type", to: encoder)
            case .audio(let content): try Tagged.encode(content, tag: "audio", key: "type", to: encoder)
            case .resourceLink(let link): try Tagged.encode(link, tag: "resource_link", key: "type", to: encoder)
            case .resource(let resource): try Tagged.encode(resource, tag: "resource", key: "type", to: encoder)
            case .unknown(let raw): try raw.encode(to: encoder)
            }
        }
    }
}
