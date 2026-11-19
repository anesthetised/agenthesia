public import ACP

extension ACP.ConfigOption {
    /// Whether `value` is the option's confirmed value.
    public func isCurrent(_ value: ACP.ConfigValue) -> Bool {
        switch (self.value, value) {
        case (.select(let current, _), .select(let wanted)): current == wanted
        case (.boolean(let current), .boolean(let wanted)): current == wanted
        default: false
        }
    }

    /// `value` as the pills name it: a choice's name (its value when the agent does not list it), `On` or `Off`.
    public func valueName(_ value: ACP.ConfigValue) -> String {
        switch (self.value, value) {
        case (.select(_, let choices), .select(let wanted)):
            choices.allOptions.first { $0.value == wanted }?.name ?? wanted
        case (_, .select(let wanted)): wanted
        case (_, .boolean(let isOn)): isOn ? "On" : "Off"
        }
    }
}
