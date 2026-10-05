extension ACP {
    public enum PlanEntryPriority: OpenEnum {
        case high, medium, low
        case unknown(String)

        public static let knownCases: [PlanEntryPriority] = [.high, .medium, .low]

        public var rawValue: String {
            switch self {
            case .high: "high"
            case .medium: "medium"
            case .low: "low"
            case .unknown(let value): value
            }
        }
    }

    public enum PlanEntryStatus: OpenEnum {
        case pending, inProgress, completed
        case unknown(String)

        public static let knownCases: [PlanEntryStatus] = [.pending, .inProgress, .completed]

        public var rawValue: String {
            switch self {
            case .pending: "pending"
            case .inProgress: "in_progress"
            case .completed: "completed"
            case .unknown(let value): value
            }
        }
    }

    public struct PlanEntry: Codable, Hashable, Sendable {
        public var content: String
        public var priority: PlanEntryPriority
        public var status: PlanEntryStatus
        public var meta: Meta?

        public init(content: String, priority: PlanEntryPriority, status: PlanEntryStatus, meta: Meta? = nil) {
            self.content = content
            self.priority = priority
            self.status = status
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case content, priority, status
            case meta = "_meta"
        }
    }

    /// The agent's plan. Every update replaces the previous plan entirely.
    public struct Plan: Codable, Hashable, Sendable {
        public var entries: [PlanEntry]
        public var meta: Meta?

        public init(entries: [PlanEntry], meta: Meta? = nil) {
            self.entries = entries
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case entries
            case meta = "_meta"
        }
    }

    /// A slash command the agent offers.
    public struct AvailableCommand: Codable, Hashable, Sendable {
        public struct Input: Codable, Hashable, Sendable {
            /// A hint shown when the command expects free-form input.
            public var hint: String
            public var meta: Meta?

            public init(hint: String, meta: Meta? = nil) {
                self.hint = hint
                self.meta = meta
            }

            private enum CodingKeys: String, CodingKey {
                case hint
                case meta = "_meta"
            }
        }

        public var name: String
        public var description: String
        public var input: Input?
        public var meta: Meta?

        public init(name: String, description: String, input: Input? = nil, meta: Meta? = nil) {
            self.name = name
            self.description = description
            self.input = input
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case name, description, input
            case meta = "_meta"
        }
    }
}
