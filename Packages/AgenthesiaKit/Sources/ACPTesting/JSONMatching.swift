public import JSONRPC

extension JSONValue {
    /// Whether this value contains `subset`: objects may have extra members, arrays must match element by
    /// element, other values must be equal.
    public func contains(_ subset: JSONValue) -> Bool {
        switch (self, subset) {
        case (.object(let object), .object(let expected)):
            expected.allSatisfy { key, value in object[key].map { $0.contains(value) } ?? false }
        case (.array(let array), .array(let expected)):
            array.count == expected.count && zip(array, expected).allSatisfy { $0.contains($1) }
        default:
            self == subset
        }
    }
}
