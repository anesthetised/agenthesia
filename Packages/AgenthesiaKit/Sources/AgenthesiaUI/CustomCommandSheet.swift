import AgenthesiaCore
import SwiftUI

/// The executable and arguments of an agent that is neither installed nor listed in Settings → Agents.
struct CustomCommandSheet: View {
    let onUse: (LocalAgent.Command) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var executable: String
    @State private var arguments: String

    init(command: LocalAgent.Command?, onUse: @escaping (LocalAgent.Command) -> Void) {
        self.onUse = onUse
        _executable = State(initialValue: command?.executable ?? "")
        _arguments = State(initialValue: command?.arguments.joined(separator: "\n") ?? "")
    }

    var body: some View {
        Form {
            // Sections give long paths the full width; a labelled field in a grouped form is short and right-aligned.
            Section("Executable") {
                TextField("Executable", text: $executable, prompt: Text("/path/to/agent or command on PATH"))
                    .labelsHidden()
            }
            Section {
                TextField("Arguments", text: $arguments, axis: .vertical).lineLimit(2...5).labelsHidden()
            } header: {
                Text("Arguments")
            } footer: {
                Text("One argument per line. Use an installed, authenticated ACP agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Command") {
                    let launch = RootView.launchCommand(executable: executable, arguments: arguments)
                    onUse(.init(executable: launch.executable, arguments: launch.arguments))
                    dismiss()
                }
                .disabled(executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
