public import Foundation

extension SessionWorkspace {
    public static let branchPrefix = "agenthesia/"
    static let maxTopicLength = 40

    /// `agenthesia/<words>-<first 8 hex digits of the session id>` (ADR-0039). The words are `topic` transliterated
    /// to Latin and reduced to at most 40 characters of `[a-z0-9-]`, cut at a word boundary; `session` without
    /// usable characters. Valid for `git check-ref-format` by construction.
    public static func branchName(for id: UUID, topic: String?) -> String {
        let latin = (topic ?? "").applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Lower"), reverse: false)
        let scalars = (latin ?? "").unicodeScalars.map {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-"
        }
        let words = String(String.UnicodeScalarView(scalars)).split(separator: "-")
        var slug = words.first.map { String($0.prefix(maxTopicLength)) } ?? "session"
        for word in words.dropFirst() {
            guard slug.count + 1 + word.count <= maxTopicLength else { break }
            slug += "-" + word
        }
        return "\(branchPrefix)\(slug)-\(id.uuidString.lowercased().prefix(8))"
    }

    /// The branch of sessions created before names were stored, and of a session whose readable name was taken.
    public static func legacyBranchName(for id: UUID) -> String { "\(branchPrefix)\(id.uuidString.lowercased())" }

    /// Whether removal may treat `branch` as the session's own: the legacy name, or a name under `agenthesia/` that
    /// ends with this session's suffix. Anything else is never deleted (ADR-0032, ADR-0039).
    static func isSessionBranch(_ branch: String, of id: UUID) -> Bool {
        branch == legacyBranchName(for: id)
            || branch.hasPrefix(branchPrefix) && branch.hasSuffix("-\(id.uuidString.lowercased().prefix(8))")
    }
}
