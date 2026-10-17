import AgenthesiaCore
import SwiftUI

struct SessionFilePane: View {
    let files: SessionFiles
    let onOpen: (String, Int?, UUID) -> Void
    @AppStorage(EditorHandoff.defaultsKey) private var editorID = ""

    var body: some View {
        let id = files.sessionID
        VStack(spacing: 0) {
            HStack {
                Text(files.selectedPath ?? "File").font(.headline)
                    .lineLimit(1).truncationMode(.middle).help(files.selectedPath ?? "")
                Spacer()
                Button("Open in Editor", systemImage: "square.and.pencil") {
                    if let path = files.selectedPath, let root = files.root {
                        EditorHandoff.open(path: path, line: files.selectedLine, root: root, editorID: editorID)
                    }
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("o", modifiers: [.command, .option])
                .help("Open in Editor (⌥⌘O)")
                Button("Reload File", systemImage: "arrow.clockwise") {
                    if let path = files.selectedPath, let id { onOpen(path, files.selectedLine, id) }
                }.labelStyle(.iconOnly)
                Button("Close File", systemImage: "xmark") {
                    guard files.sessionID == id else { return }
                    files.closeDocument()
                }.labelStyle(.iconOnly)
            }.padding(8)
            Divider()
            if files.isLoadingDocument {
                ProgressView("Loading file…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = files.documentError {
                ContentUnavailableView {
                    Label("Cannot preview file", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error).textSelection(.enabled)
                }
            } else if let document = files.document {
                FileViewer(document: document, line: files.selectedLine)
            }
        }
    }
}
