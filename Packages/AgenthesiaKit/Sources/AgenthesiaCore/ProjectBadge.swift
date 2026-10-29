/// What a sidebar row's project badge shows, derived from the project name alone (ADR-0039).
public enum ProjectBadge {
    /// The first letters of the first two words (split on space, `-`, `_` and `.`), uppercased; one word gives
    /// its first two letters.
    public static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { " -_.".contains($0) })
        let letters =
            words.count > 1
            ? words.prefix(2).compactMap(\.first).map(String.init) : words.first.map { [String($0.prefix(2))] }
        return (letters ?? []).joined().uppercased()
    }

    /// 64-bit FNV-1a of the UTF-8 name. `hashValue` is seeded per launch, so it would recolor every badge.
    public static func hash(_ name: String) -> UInt64 {
        name.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}
