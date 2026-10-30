import AgenthesiaCore
import AppKit
import Persistence
import SwiftUI
import Workspace

/// The displayed session's details beside its transcript: workspace, branch, changes and agent (ADR-0039).
struct SessionInspector: View {
    let model: SessionWindowModel
    @Binding var showingLog: Bool
    let onOpen: (String, UUID) -> Void
    @AppStorage(EditorHandoff.defaultsKey) private var editorID = ""

    private var session: SessionRecord? { model.displayed?.session }

    private var directory: URL? {
        session.map { URL(filePath: $0.workingDirectory) } ?? model.owner?.workingDirectory
    }

    var body: some View {
        Form {
            if let directory { workspace(directory) }
            if let session {
                if let name = Self.branchName(of: session) { branch(name, base: session.baseBranch) }
                if model.files.root != nil, model.files.sessionID == session.id { changes(session) }
            }
            if model.restored == nil, let owner = model.owner { agent(owner) }
        }.formStyle(.grouped)
    }

    private func workspace(_ directory: URL) -> some View {
        Section("Workspace") {
            Text(directory.path).lineLimit(1).truncationMode(.middle).help(directory.path)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
            }
            Button("Open in Editor", systemImage: "square.and.pencil") {
                EditorHandoff.open(path: "", line: nil, root: directory, editorID: editorID)
            }
        }
    }

    /// The branch of the worktree Agenthesia created for the session; sessions without a base have none.
    static func branchName(of session: SessionRecord) -> String? {
        session.baseRevision == nil ? nil : "agenthesia/\(session.id.uuidString.lowercased())"
    }

    private func branch(_ name: String, base: String?) -> some View {
        Section("Branch") {
            LabeledContent("Branch", value: name)
            if let base { LabeledContent("Base", value: base) }
        }
    }

    private func changes(_ session: SessionRecord) -> some View {
        let files = model.files
        return Section("Changes") {
            if let error = files.changesError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if files.isLoadingIndex {
                ProgressView("Checking files…").controlSize(.small)
            } else if !files.isGitRepository {
                Text("Change tracking requires Git.").font(.caption).foregroundStyle(.secondary)
            } else if files.changedPaths.isEmpty {
                Text("No changed files").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ChangeCounts(lines: files.changeStats.total)
                    Text("· ^[\(files.changedPaths.count) file](inflect: true)").foregroundStyle(.secondary)
                }
            }
            ForEach(files.changedPaths, id: \.self) { path in
                Button {
                    onOpen(path, session.id)
                } label: {
                    HStack {
                        Label(path, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if files.changeStats.binary.contains(path) {
                            Text("binary").font(.caption).foregroundStyle(.secondary)
                        } else if let lines = files.changeStats.files[path] {
                            ChangeCounts(lines: lines).font(.caption)
                        }
                    }.contentShape(.rect)
                }.buttonStyle(.plain).help(path)
            }
            if let error = files.watchError {
                Text("Automatic refresh is unavailable: \(error)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Refresh Files", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
            Button("Review Changes…", systemImage: "doc.text.magnifyingglass", action: model.openReview)
                .disabled(!model.canReview)
            Button(model.mergeCommandTitle, systemImage: "arrow.triangle.merge") {
                Task { await model.requestMerge() }
            }.disabled(!model.canMerge)
            Button("Discard Worktree…", systemImage: "trash") { Task { await model.requestDiscard(session) } }
                .disabled(!model.canDiscard)
        }
    }

    private func agent(_ owner: LiveSession) -> some View {
        Section("Agent") {
            if let name = owner.agentName { LabeledContent("Agent", value: name) }
            Toggle("Agent Log", systemImage: "terminal", isOn: $showingLog)
        }
    }
}

/// `+added −removed`, in the colors of a diff.
struct ChangeCounts: View {
    let lines: ChangeStats.Lines

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(lines.added)").foregroundStyle(.green)
            Text("−\(lines.removed)").foregroundStyle(.red)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(lines))
    }

    static func label(_ lines: ChangeStats.Lines) -> String { "\(lines.added) added, \(lines.removed) removed" }
}
