import AgenthesiaCore
import AppKit
import SwiftTerm
import SwiftUI

/// A SwiftTerm view connected to a sign-in command's pseudo-terminal.
struct TerminalHost: NSViewRepresentable {
    let terminal: SignInTerminal

    func makeCoordinator() -> Coordinator { Coordinator(terminal: terminal) }

    func makeNSView(context: Context) -> TerminalView {
        let view = FocusedTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        view.terminalDelegate = context.coordinator
        context.coordinator.feed(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: TerminalViewDelegate {
        let terminal: SignInTerminal
        private var feeding: Task<Void, Never>?

        init(terminal: SignInTerminal) { self.terminal = terminal }

        func feed(_ view: TerminalView) {
            let output = terminal.output()
            feeding = Task { [weak view] in
                for await chunk in output { view?.feed(byteArray: [UInt8](chunk)[...]) }
            }
        }

        func stop() { feeding?.cancel() }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            terminal.resize(columns: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { terminal.write(Data(data)) }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
