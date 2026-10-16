import AgenthesiaCore
import SwiftUI

struct SessionChangedFiles: View {
    let files: SessionFiles
    let onOpen: (String, UUID) -> Void

    var body: some View {
        let id = files.sessionID
        Section(files.baseRevision == nil ? "Working changes" : "Changed files") {
            if files.root != nil {
                Text("Session working directory").font(.caption).foregroundStyle(.secondary)
            }
            if let error = files.changesError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if files.isLoadingIndex {
                ProgressView("Checking files…").controlSize(.small)
            } else if !files.isGitRepository {
                Text("Change tracking requires Git.").font(.caption).foregroundStyle(.secondary)
            } else if files.changedPaths.isEmpty {
                Text("No changed files").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files.changedPaths, id: \.self) { path in
                Button {
                    if let id { onOpen(path, id) }
                } label: {
                    Label(path, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).help(path)
            }
            Button("Refresh Files", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
        }
    }
}
