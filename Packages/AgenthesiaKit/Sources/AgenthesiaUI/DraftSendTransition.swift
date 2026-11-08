import SwiftUI

/// Send's removal transition for the draft: its card moves to the bottom edge and fades, the heading first.
struct DraftSendTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.environment(\.draftLeaving, phase == .didDisappear).opacity(phase == .didDisappear ? 0 : 1)
    }
}

extension EnvironmentValues {
    @Entry var draftLeaving = false
}
