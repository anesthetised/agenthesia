public import ACP

/// What a surface that shows no transcript offers for a pending permission request (ADR-0046): the agent's options in
/// the agent's order, behind **Open** when the request edits files. Answering without reading the transcript is safe
/// for a command or a fetch; an edit is looked at first. The menu bar item reads it, and so will the session board.
public enum PermissionChoice: Identifiable, Equatable, Sendable {
    case open
    case option(ACP.PermissionOption)

    public var id: String {
        switch self {
        case .open: "open"
        case .option(let option): "option:\(option.optionId)"
        }
    }

    /// - Parameter openAlways: Offer Open even for a request without a diff, where the surface has no other way to
    ///   open the session, such as a menu item that is a submenu.
    public static func choices(
        for request: SessionController.PendingPermission,
        openAlways: Bool = false
    ) -> [PermissionChoice] {
        let hasDiff = (request.toolCall.content ?? []).contains { if case .diff = $0 { true } else { false } }
        return (hasDiff || openAlways ? [.open] : []) + request.options.map(PermissionChoice.option)
    }
}
