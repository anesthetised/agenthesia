/// The draft's heading: a question with the project's menu in it, or, without a project, the menu alone.
struct DraftHeading: Equatable {
    /// The words before the menu; nil without a project.
    let lead: String?
    /// The menu's title.
    let menu: String
    /// What follows the menu.
    let end: String

    init(project: String?) {
        if let project {
            (lead, menu, end) = ("What should we build in", project, "?")
        } else {
            (lead, menu, end) = (nil, "Choose a project to start", "")
        }
    }

    var text: String { [lead, menu + end].compactMap(\.self).joined(separator: " ") }
}
