/// The draft's heading: a question with the project's menu in it, or, without a project, the menu alone. A draft
/// without a project (ADR-0048) asks its own question and has no menu.
struct DraftHeading: Equatable {
    /// The words before the menu; nil without a project.
    let lead: String?
    /// The menu's title; nil for a draft without a project.
    let menu: String?
    /// What follows the menu.
    let end: String
    /// The secondary line under the heading that switches between a project and none.
    let alternative: String

    init(project: String?, withoutProject: Bool = false) {
        if withoutProject {
            (lead, menu, end) = ("What should we work on?", nil, "")
            alternative = "in a project"
            return
        }
        if let project {
            (lead, menu, end) = ("What should we build in", project, "?")
        } else {
            (lead, menu, end) = (nil, "Choose a project to start", "")
        }
        alternative = "or start without a project"
    }

    var text: String { [lead, menu.map { $0 + end }].compactMap(\.self).joined(separator: " ") }
}
