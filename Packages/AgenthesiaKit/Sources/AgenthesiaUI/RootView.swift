import AgenthesiaCore
import AppKit
public import SwiftUI

public struct RootView: View {
    @State private var model = SessionWindowModel()
    @State private var prompt = ""
    @State private var directory = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var showingSetup = true
    @State private var showingLog = false
    @FocusState private var composerFocused: Bool

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {
                if let owner = model.owner {
                    Section("Current session") {
                        Button {
                            model.showLive(); showingSetup = false
                        } label: {
                            Label(
                                owner.controller?.session.title ?? "Starting session",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        }.buttonStyle(.plain)
                    }
                }
                Section("Saved sessions") {
                    ForEach(model.history.filter { $0.id != model.owner?.controller?.session.id }) { record in
                        Button {
                            showingSetup = false
                            prompt = ""
                            Task { await model.showHistory(record) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(record.title ?? "Session")
                                Text(record.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Agenthesia")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Session", systemImage: "plus") { showingSetup = true }
                    .disabled(!model.canStart).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Refresh History", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        } detail: {
            VStack(spacing: 0) {
                if showingSetup && model.canStart {
                    setup
                } else if model.isLoadingHistory {
                    ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session = model.displayed {
                    LiveTranscript(session: session).id(session.session.id)
                    Divider()
                    composer(session)
                } else {
                    ContentUnavailableView(
                        model.owner?.isStarting == true ? "Starting session…" : "Start a session",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a project and an installed ACP agent.")
                    )
                }
                if model.restored == nil, let diagnostic = model.owner?.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if let error = model.errorMessage ?? (model.restored == nil ? model.owner?.errorMessage : nil) {
                    Text(error).textSelection(.enabled).foregroundStyle(.red).padding().frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                if let path = model.displayed.map({ URL(filePath: $0.session.workingDirectory) })
                    ?? model.owner?.workingDirectory
                {
                    HStack {
                        Text(path.path).lineLimit(1).truncationMode(.middle).help(path.path)
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if showingLog, let owner = model.owner {
                    Divider()
                    ScrollView {
                        Text(owner.stderrLog.isEmpty ? "No stderr output." : owner.stderrLog)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.frame(height: 150)
                }
            }
            .navigationTitle(model.displayed?.title ?? model.displayed?.session.title ?? "New Session")
            .toolbar {
                if let owner = model.owner {
                    Button("Agent Log", systemImage: "terminal") { showingLog.toggle() }
                    Button(owner.isStarting ? "Cancel Startup" : "End Session", systemImage: "stop.circle") {
                        Task {
                            await owner.close(); await model.refresh()
                        }
                    }.disabled(owner.isClosed)
                }
            }
        }
        .frame(minWidth: 740, minHeight: 500)
        .background(SessionWindowLifetime(model: model).frame(width: 0, height: 0))
        .task { await model.refresh() }
    }

    private var setup: some View {
        Form {
            Section("New session") {
                HStack {
                    TextField("Project directory", text: $directory)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { directory = panel.url?.path ?? "" }
                    }
                }
                TextField("Agent executable", text: $executable, prompt: Text("/path/to/agent or command on PATH"))
                TextField("Arguments", text: $arguments, axis: .vertical).lineLimit(2...5)
                Text(
                    "One argument per line. Use an installed, authenticated ACP agent. Git projects get a fresh worktree from HEAD; uncommitted and untracked files are not copied. Other directories are used directly."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Start Session") {
                    showingSetup = false
                    let command = Self.launchCommand(executable: executable, arguments: arguments)
                    let path = (directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                    Task {
                        await model.start(
                            directory: URL(filePath: path),
                            executable: command.executable,
                            arguments: command.arguments
                        )
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(directory.isEmpty || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.formStyle(.grouped)
    }

    private func composer(_ session: SessionController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message the agent…", text: $prompt, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.plain).focused($composerFocused)
                .disabled(![.idle, .running, .stopping].contains(session.status))
                .onKeyPress(keys: [.return], phases: .down) { press in
                    Self.handleComposerReturn(modifiers: press.modifiers, responder: NSApp.keyWindow?.firstResponder)
                }.onSubmit(send)
                .accessibilityLabel("Message")
            HStack {
                Text(
                    session.status == .readOnly
                        ? "Saved history · read-only" : String(describing: session.status).capitalized
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.status == .running || session.status == .stopping {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.owner?.stop() } }
                        .keyboardShortcut(".", modifiers: .command).disabled(session.status == .stopping)
                } else {
                    Button("Send", systemImage: "arrow.up", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(
                            session.status != .idle || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }.padding(16).background(.bar)
    }

    private func send() {
        guard model.restored == nil, model.owner?.controller?.status == .idle,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let text = prompt
        prompt = ""
        Task { await model.owner?.send(text) }
    }

    static func launchCommand(executable: String, arguments: String) -> (executable: String, arguments: [String]) {
        let path = (executable.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return (path, arguments.split(separator: "\n").map(String.init))
    }

    static func handleComposerReturn(modifiers: EventModifiers, responder: NSResponder?) -> KeyPress.Result {
        guard modifiers == .shift, let editor = responder as? NSTextView else { return .ignored }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return .handled
    }
}

#Preview { RootView() }
