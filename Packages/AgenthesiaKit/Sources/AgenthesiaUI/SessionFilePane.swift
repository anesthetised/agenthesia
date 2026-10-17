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
                Button("Open in Editor", systemImage: "square.and.pencil", action: openInEditor)
                    .labelStyle(.iconOnly)
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
                // Fills the pane, as the loading and file views do, so the header stays at the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document = files.document {
                FileViewer(document: document, line: files.selectedLine)
            }
        }
        .focusedSceneValue(\.openInEditor, editorAction)
    }

    /// The File menu's Open in Editor, available while a file is selected.
    private var editorAction: (() -> Void)? {
        guard files.selectedPath != nil else { return nil }
        return openInEditor
    }

    private func openInEditor() {
        guard let path = files.selectedPath, let root = files.root else { return }
        EditorHandoff.open(path: path, line: files.selectedLine, root: root, editorID: editorID)
    }
}
