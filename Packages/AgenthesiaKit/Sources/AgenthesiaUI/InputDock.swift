import ACP
import AgenthesiaCore
import JSONRPC
import SwiftUI

/// The oldest pending form, docked at the top of the composer card and answered one step at a time (#326). While it
/// waits, the composer's text is the current step's text answer; the user's draft stays in `ComposerDraft`.
@MainActor struct DockedInput {
    let input: SessionController.PendingInput
    let schema: ACP.ElicitationSchema
    let steps: [InputStep]
    let draft: InputDraft
    /// Commits a response; false when the controller refuses it (ADR-0020).
    let answer: (ACP.ElicitationResponse) -> Bool

    init(
        input: SessionController.PendingInput,
        schema: ACP.ElicitationSchema,
        draft: InputDraft,
        answer: @escaping (ACP.ElicitationResponse) -> Bool
    ) {
        self.input = input
        self.schema = schema
        steps = InputStep.steps(schema)
        self.draft = draft
        self.answer = answer
    }

    var index: Int { min(max(draft.step, 0), steps.count - 1) }
    var step: InputStep { steps[index] }
    var isLast: Bool { index == steps.count - 1 }
    /// `1 of 3` while the form has several steps.
    var progress: String? { steps.count > 1 ? "\(index + 1) of \(steps.count)" : nil }

    private func field(_ key: String?) -> ACP.PropertySchema? { key.flatMap { schema.properties[$0] } }
    private func isRequired(_ key: String) -> Bool { schema.required?.contains(key) == true }

    /// The step's field title, falling back to its name as the transcript's record does.
    var title: String {
        guard let key = step.keys.first else { return "Answer" }
        let title = field(key).flatMap { InputField.metadata($0).title } ?? key
        return title + (isRequired(key) ? " (required)" : "")
    }

    /// The step's own question, or the form's message when the step has none.
    var question: String? {
        let description = step.keys.first.flatMap { field($0) }.flatMap { InputField.metadata($0).description }
        return description ?? (input.request.message.isEmpty ? nil : input.request.message)
    }

    /// The form's message above a step that brings its own question.
    var message: String? {
        question == input.request.message || input.request.message.isEmpty ? nil : input.request.message
    }

    var choices: [ACP.EnumOption] { InputStep.choices(field(step.control)) }
    var isMultiple: Bool { if case .multiSelect = field(step.control) { true } else { false } }

    func isPicked(_ option: ACP.EnumOption) -> Bool {
        guard let key = step.control else { return false }
        return switch draft.values[key] {
        case .string(let value): value == option.const
        case .array(let values): values.contains(.string(option.const))
        default: false
        }
    }

    /// Picks the choice at `index` (1–9 or a click); a multiple choice toggles it.
    func pick(_ index: Int) {
        guard let key = step.control, let field = field(key), choices.indices.contains(index) else { return }
        let choice = choices[index].const
        if isMultiple {
            draft.toggle(choice, in: key, required: isRequired(key))
        } else {
            draft.edit(key, text: choice, field: field)
        }
    }

    /// Moves a single choice up or down (↑ and ↓ in an empty composer); from no pick, ↓ picks the first and ↑ the
    /// last. A multiple choice is toggled with 1–9 only.
    func movePick(by offset: Int) {
        guard !isMultiple, !choices.isEmpty else { return }
        let current = choices.firstIndex(where: isPicked)
        let next = current.map { $0 + offset } ?? (offset > 0 ? 0 : choices.count - 1)
        pick(min(max(next, 0), choices.count - 1))
    }

    /// The composer's text: the step's text answer. An optional field left empty is left out of the response.
    var text: String {
        get { step.text.flatMap { draft.text[$0] } ?? "" }
        nonmutating set {
            guard let key = step.text, let field = field(key) else { return }
            if newValue.isEmpty, !isRequired(key) {
                draft.omit(key)
            } else {
                draft.edit(key, text: newValue, field: field)
            }
        }
    }

    /// Whether the composer's text answers this step; it is read-only on a step that only shows a control.
    var takesText: Bool { step.text != nil }

    var placeholder: String {
        guard let key = step.text else { return "Return continues" }
        return field(key).flatMap { InputField.metadata($0).description ?? InputField.metadata($0).title }
            ?? "Your answer"
    }

    /// The errors to show: the step's own, and on the last step those of any field not shown in a step.
    var errors: [(key: String, message: String)] {
        let all = InputValidation.errors(in: draft.values, schema: schema)
        let keys = isLast ? Set(all.keys) : Set(step.keys)
        return all.filter { keys.contains($0.key) }.sorted { $0.key < $1.key }.map {
            (key: $0.key, message: step.keys.contains($0.key) ? $0.value : "\($0.key): \($0.value)")
        }
    }

    /// Return (`Next` or `Answer`) is available once the step, and on the last step the whole form, is valid.
    var canAdvance: Bool { errors.isEmpty }

    /// Moves to the next step, or sends the response from the last one.
    @discardableResult func advance() -> Bool {
        guard canAdvance else { return false }
        if isLast { return answer(.init(action: .accept(draft.values))) }
        draft.step = index + 1
        return true
    }

    /// Back shows the previous step; the answers of every step stay in the draft, and nothing reaches the agent until
    /// the last step is answered.
    var canGoBack: Bool { index > 0 }

    @discardableResult func goBack() -> Bool {
        guard canGoBack else { return false }
        draft.step = index - 1
        return true
    }

    /// Skip and Escape decline the form, as the transcript card's Decline did (ADR-0020).
    @discardableResult func decline() -> Bool { answer(.init(action: .decline)) }

    /// VoiceOver reads the step, its progress and its question.
    var announcement: String {
        ["Question", progress, title].compactMap(\.self).joined(separator: " ") + (question.map { ": \($0)" } ?? "")
    }
}

/// The docked form's current step: its question, choices and errors, with `1 of 3` and Skip (#326). It never takes
/// focus: the composer keeps it, and its keys answer the step.
struct InputDock: View {
    let form: DockedInput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = form.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(form.title).fontWeight(.semibold)
                Spacer(minLength: 8)
                if form.canGoBack {
                    Button("Back", action: goBack)
                        .help("Go back to the previous question")
                        .accessibilityLabel("Back, previous question")
                }
                if let progress = form.progress {
                    Text(progress).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Skip", action: skip)
                    .help("Decline the agent's questions (Escape)")
            }
            if let question = form.question {
                Text(question).fixedSize(horizontal: false, vertical: true)
            }
            if !form.choices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(form.choices.enumerated(), id: \.element.const) { index, option in
                        InputChoiceRow(
                            option: option,
                            number: index < 9 ? index + 1 : nil,
                            multiple: form.isMultiple,
                            picked: form.isPicked(option)
                        ) { form.pick(index) }
                    }
                }
            } else if let key = form.step.control, let field = form.schema.properties[key] {
                InputField(key: key, field: field, schema: form.schema, draft: form.draft, error: nil)
            }
            ForEach(form.errors, id: \.key) { error in
                Text(error.message).font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(form.announcement)
        .onChange(of: form.index, initial: true) {
            AccessibilityNotification.Announcement(form.announcement).post()
        }
    }

    private func goBack() { form.goBack() }
    private func skip() { form.decline() }
}

/// One choice: its number for 1–9, a radio or checkbox mark, the title and the agent's description.
private struct InputChoiceRow: View {
    let option: ACP.EnumOption
    let number: Int?
    let multiple: Bool
    let picked: Bool
    let action: () -> Void

    private var mark: String {
        switch (multiple, picked) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number.map(String.init) ?? " ").foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityHidden(true)
                Image(systemName: mark).foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    if let description = option.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(.rect)
            .background(picked ? AnyShapeStyle(.tint.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(number.map { "Press \($0) to choose" } ?? "")
    }
}
