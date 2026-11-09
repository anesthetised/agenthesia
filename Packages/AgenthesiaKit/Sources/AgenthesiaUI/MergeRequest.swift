import AgenthesiaCore
import Foundation
import Observation
import Persistence

/// The merge sheet's state for one session (ADR-0032).
@Observable final class MergeRequest: Identifiable {
    let session: SessionRecord
    /// Nil while Git is being asked.
    var check: SessionManager.MergeCheck?
    var message: String
    var isMerging = false
    var failure: SessionManager.MergeError?
    var id: UUID { session.id }

    init(session: SessionRecord, message: String) {
        self.session = session
        self.message = message
    }

    var title: String { session.baseBranch.map { "Merge into \($0)" } ?? "Merge" }

    static let pushDefaultsKey = "pushAfterMerge"

    /// The merge pushes the base branch: it has a remote upstream and the remembered choice is on (ADR-0045).
    var pushes: Bool {
        guard case .ready(_, _, _, _?) = check else { return false }
        return UserDefaults.standard.bool(forKey: Self.pushDefaultsKey)
    }

    var canMerge: Bool {
        guard case .ready = check, !isMerging else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A blocker replaces the Merge button with its explanation.
    var isBlocked: Bool {
        if case .blocked = check { true } else { false }
    }
}
