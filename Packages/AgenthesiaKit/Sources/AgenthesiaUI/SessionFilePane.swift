import AgenthesiaCore
import SwiftUI

struct SessionFilePane: View {
    let files: SessionFiles
    let onOpen: (String, UUID) -> Void

    var body: some View {
        let id = files.sessionID
        VStack(spacing: 0) {
            HStack {
                Text(files.selectedPath ?? "File").font(.headline)
                    .lineLimit(1).truncationMode(.middle).help(files.selectedPath ?? "")
                Spacer()
                Button("Reload File", systemImage: "arrow.clockwise") {
                    if let path = files.selectedPath, let id { onOpen(path, id) }
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
                FileViewer(document: document)
            }
        }
    }
}
