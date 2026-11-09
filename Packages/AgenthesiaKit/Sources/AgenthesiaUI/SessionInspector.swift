import AgenthesiaCore
import AppKit
import Persistence
import SwiftUI
import Workspace

/// The displayed session's details beside its transcript: plan, changes, workspace and branch, and agent (ADR-0039).
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
            if let displayed = model.displayed, let plan = displayed.transcript.plan, let progress = PlanProgress(plan)
            {
                PlanSection(plan: plan, progress: progress, running: displayed.turnStartedAt != nil)
                    .id(displayed.session.id)
            }
            if let session, model.files.root != nil, model.files.sessionID == session.id { changes(session) }
            if let directory { workspace(directory, session: session) }
            if model.restored == nil, let owner = model.owner { agent(owner) }
        }.formStyle(.grouped)
    }

    private func workspace(_ directory: URL, session: SessionRecord?) -> some View {
        Section {
            if let session, model.displaysProjectFolderSession {
                Label(Self.projectFolder(of: session), systemImage: "arrow.triangle.branch").textSelection(.enabled)
            } else if let session, let name = Self.branchName(of: session) {
                VStack(alignment: .leading) {
                    Label(name, systemImage: "arrow.triangle.branch")
                    if let start = Self.start(of: session) { Text(start).foregroundStyle(.secondary) }
                }.textSelection(.enabled)
            }
            Label(directory.path, systemImage: "folder").textSelection(.enabled)
            // A session without a project has no worktree to discard (ADR-0048).
            if let session, !model.displaysSessionWithoutProject {
                Button("Discard Worktree…", systemImage: "trash") { Task { await model.requestDiscard(session) } }
                    .buttonStyle(.borderless)
                    .disabled(!model.canDiscard)
                    .help(model.discardHelp ?? "")
            }
        } header: {
            HStack {
                Text("Workspace")
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                }.help("Show in Finder")
                Button("Open in Editor", systemImage: "square.and.pencil") {
                    EditorHandoff.open(path: "", line: nil, root: directory, editorID: editorID)
                }.help("Open in Editor")
            }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    /// The branch of the worktree Agenthesia created for the session: the stored name, or the legacy one derived from
    /// the session id. Sessions without a base have none.
    static func branchName(of session: SessionRecord) -> String? {
        session.baseRevision == nil ? nil : session.branch ?? SessionWorkspace.legacyBranchName(for: session.id)
    }

    /// What a session in the project folder works on (ADR-0043): `In main, project folder`, or the short commit of a
    /// detached `HEAD`. It has no branch of its own, so no legacy name is derived.
    static func projectFolder(of session: SessionRecord) -> String {
        "In \(session.baseBranch ?? String(session.baseRevision?.prefix(7) ?? "HEAD")), project folder"
    }

    /// Where the worktree started: `from main`, or the local branch when its upstream could not be fetched
    /// (ADR-0047). Sessions without a base branch have none.
    static func start(of session: SessionRecord) -> String? {
        guard let base = session.baseBranch else { return nil }
        guard let upstream = session.fallbackUpstream else { return "from \(base)" }
        return "Started from local \(base): could not fetch \(upstream)"
    }

    private func changes(_ session: SessionRecord) -> some View {
        let files = model.files
        return Section(model.displaysProjectFolderSession ? "Changes since the session started" : "Changes") {
            if model.displaysSessionWithoutProject {
                // Not a project: nothing is tracked, reviewed or merged (ADR-0048).
                Text("Not tracked: this session has no project").font(.caption).foregroundStyle(.secondary)
            } else {
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
                actions
                if let pullRequest = model.displayedPullRequest { self.pullRequest(pullRequest) }
                WatchErrorNotice(files: files)
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
            }
        }
    }

    /// Review leads while there are changes; the buttons wrap onto rows of their own when the pane is narrow.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { actionButtons }
            VStack(alignment: .leading) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        review(prominent: !model.files.changedPaths.isEmpty)
        // A session with a pull request integrates through it, not a local merge (ADR-0045).
        if model.showsMerge {
            Button(model.mergeCommandTitle, systemImage: "arrow.triangle.merge") { Task { await model.requestMerge() } }
                .buttonStyle(.bordered)
                .disabled(!model.canMerge)
                .help(model.mergeHelp ?? "")
        }
        if model.showsOpenPullRequest {
            Button("Open Pull Request…", systemImage: "arrow.triangle.pull", action: model.requestPullRequest)
                .buttonStyle(.bordered)
                .disabled(!model.canOpenPullRequest)
        }
    }

    /// The pull request opened from the session, with Push while the worktree has work it lacks (ADR-0045).
    private func pullRequest(_ pullRequest: PullRequest) -> some View {
        HStack {
            Link("Pull request #\(pullRequest.number)", destination: pullRequest.url)
                .help(pullRequest.url.absoluteString)
            Spacer(minLength: 8)
            if model.isPushing {
                ProgressView().controlSize(.small)
            } else if model.showsPush {
                Button("Push", systemImage: "arrow.up") { Task { await model.pushPullRequestBranch() } }
                    .buttonStyle(.bordered)
                    .help("Push the new work to the pull request")
            }
        }
    }

    @ViewBuilder private func review(prominent: Bool) -> some View {
        let button = Button("Review", systemImage: "text.badge.checkmark", action: model.toggleReview)
            .disabled(!model.canReview)
            .help(model.isReviewShown ? "Hide the review (⌃⌘R)" : "Review the changes (⌃⌘R)")
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }

    private func agent(_ owner: LiveSession) -> some View {
        Section("Agent") {
            if let name = owner.agentName { LabeledContent("Name", value: name) }
            if let usage = ContextUsage(owner.controller?.transcript.usage) {
                LabeledContent("Context", value: usage.summary)
                if let cost = usage.costText { LabeledContent("Cost", value: cost) }
            }
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

/// Why the file list does not refresh itself, with the way out: a manual refresh.
struct WatchErrorNotice: View {
    let files: SessionFiles

    var body: some View {
        if let error = files.watchError {
            HStack {
                Text("Automatic refresh is unavailable: \(error)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Refresh Files", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Refresh Files")
            }
        }
    }
}
