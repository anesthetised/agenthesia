import ACP
import AgenthesiaCore

struct InputCard: Equatable {
    let input: TranscriptState.Input
    let active: Bool
    let recording: Bool
    let draft: InputDraft
    let answer: (ACP.ElicitationResponse) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.active == rhs.active && lhs.recording == rhs.recording
    }
}
