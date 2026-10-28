import AgenthesiaCore
import SwiftUI

/// A terminal sign-in method's command in a sheet over the session window (ADR-0033).
struct SignInTerminalSheet: View {
    let terminal: SignInTerminal
    /// Cancels a running command or closes a failed one.
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(terminal.title).font(.headline).padding()
            TerminalHost(terminal: terminal)
                .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 440)
            Divider()
            HStack {
                if let exit = terminal.exitMessage {
                    Label(exit, systemImage: "xmark.octagon")
                } else {
                    Text("Follow the instructions in the terminal.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(terminal.exitMessage == nil ? "Cancel" : "Close", action: onDone)
            }
            .padding()
        }
        // Escape belongs to the program in the terminal.
        .interactiveDismissDisabled()
        .background { SignInSheetTermination() }
    }
}
