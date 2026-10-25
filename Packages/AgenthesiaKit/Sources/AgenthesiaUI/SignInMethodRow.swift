import ACP

/// One of the agent's sign-in methods as the panel lists it (ADR-0033).
struct SignInMethodRow: Identifiable, Equatable {
    let id: ACP.AuthMethodID
    let name: String
    let detail: String?
    let opensTerminal: Bool
    let isSupported: Bool

    static func rows(_ methods: [ACP.AuthMethod]) -> [SignInMethodRow] {
        methods.enumerated().map { index, method in
            switch method {
            case .agent(let method):
                SignInMethodRow(
                    id: method.id,
                    name: method.name,
                    detail: method.description,
                    opensTerminal: false,
                    isSupported: true
                )
            case .terminal(let method):
                SignInMethodRow(
                    id: method.id,
                    name: method.name,
                    detail: method.description,
                    opensTerminal: true,
                    isSupported: true
                )
            case .unknown(let raw):
                SignInMethodRow(
                    id: raw["id"]?.stringValue ?? "unknown-\(index)",
                    name: raw["name"]?.stringValue ?? "Unknown method",
                    detail: "Agenthesia does not support this method.",
                    opensTerminal: false,
                    isSupported: false
                )
            }
        }
    }
}
