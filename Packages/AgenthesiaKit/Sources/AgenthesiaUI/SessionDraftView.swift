import AgenthesiaCore
import AppKit
import SwiftUI

/// A window without a session (ADR-0040): an empty transcript area and the composer card, with the project, agent and
/// checkout above the text. Send starts the session with the draft as its first message.
struct SessionDraftView: View {
    @Bindable var model: SessionWindowModel
    @State private var checkout: DraftCheckout?
    @State private var editingCommand = false
    @State private var catalogLoaded = false

    /// The pills' tooltip and accessibility note: what they show is a cached hint, not a session's confirmed value.
    static let hintNote = "Last used with this agent; confirmed when the session starts"

    var body: some View {
        VStack(spacing: 0) {
            Text("What should the agent do?")
                .font(.title2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.draftError {
                    FailureBanner(error, offering: [.manageAgents], perform: { _ in })
                }
                if catalogLoaded, model.selectedAgent == nil, model.catalog?.choices.isEmpty == true {
                    HStack {
                        Text("No agent is installed.").foregroundStyle(.secondary)
                        ManageAgentsButton()
                    }
                    .font(.caption)
                }
                card
            }
            .frame(maxWidth: TranscriptColumn.maxWidth)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .task {
            await model.catalog?.reloadInstallations()
            catalogLoaded = true
        }
        .task(id: model.selectedDirectory) {
            checkout = nil
            if let directory = model.selectedDirectory { checkout = await DraftCheckout.of(directory) }
        }
        .sheet(isPresented: $editingCommand) {
            CustomCommandSheet(command: customCommand) { model.draftAgent = .custom($0) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                projectMenu
                agentMenu
                if let checkout {
                    Label(checkout.title, systemImage: checkout == .folder ? "folder" : "arrow.triangle.branch")
                        .foregroundStyle(.secondary).lineLimit(1).help(checkout.help)
                }
                Spacer(minLength: 0)
            }
            ComposerInput(
                text: $model.draft.text,
                attachments: $model.draft.attachments,
                commands: [],
                isEnabled: true,
                onSubmit: { _ in model.startDraft() }
            )
            HStack(spacing: 8) {
                Button("Attach Files…", systemImage: "paperclip", action: chooseAttachments)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Attach files or folders (⇧⌘A)")
                hintPills
                Spacer(minLength: 0)
                Button("Send", systemImage: "arrow.up", action: model.startDraft)
                    .labelStyle(.iconOnly).buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .help("Start the session with this message (Return)")
                    .disabled(!model.canStartDraft)
            }
        }
        .padding(12)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
        .dropDestination(for: URL.self) { urls, _ in
            ComposerInput.add(urls, to: &model.draft.attachments)
            return true
        }
    }

    /// The agent's cached mode, model and effort (ADR-0040): hints, so drawn as secondary and worded as such. A mode reads
    /// `Default mode` until one is picked, because only a picked mode is applied.
    private var hintPills: some View {
        ForEach(model.draftPills, id: \.id) { option in
            if case .select(_, let choices) = option.value {
                ConfigSelectMenu(
                    option: option,
                    choices: choices,
                    selected: model.draftValue(of: option),
                    placeholder: "Default mode",
                    note: Self.hintNote
                ) { model.draftConfig[option.id] = $0 }
                // A borderless menu draws its title in the control's color whatever the foreground style says.
                .opacity(0.6)
            }
        }
    }

    private var projectMenu: some View {
        let selected = model.selectedDirectory
        let projects = model.recentProjects
        return Menu {
            ForEach(projects) { project in
                let directory = URL(filePath: project.rootPath, directoryHint: .isDirectory)
                Button {
                    model.draftDirectory = directory
                } label: {
                    if directory.path() == selected?.path() {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            if !projects.isEmpty { Divider() }
            Button("Choose Folder…", action: chooseFolder)
        } label: {
            Label(
                projects.first { $0.rootPath == selected?.path(percentEncoded: false) }?.name
                    ?? selected?.lastPathComponent ?? "Choose Project",
                systemImage: "folder"
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel("Project: \(selected?.lastPathComponent ?? "none")")
        .help(selected?.path(percentEncoded: false) ?? "Choose the project the agent works in")
    }

    private var agentMenu: some View {
        let selected = model.selectedAgent
        let choices = model.catalog?.choices ?? []
        return Menu {
            ForEach(choices, id: \.self) { choice in
                let name = model.catalog?.name(of: choice) ?? ""
                Button {
                    model.draftAgent = choice
                } label: {
                    if choice == selected { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !choices.isEmpty { Divider() }
            Button("Custom Command…") { editingCommand = true }
            ManageAgentsButton()
        } label: {
            Label(selected.flatMap(agentName) ?? "Choose Agent", systemImage: "cpu")
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel("Agent: \(selected.flatMap(agentName) ?? "none")")
        .help("The agent that starts the session")
    }

    private func agentName(_ choice: AgentCatalog.Choice) -> String? {
        model.catalog?.name(of: choice) ?? model.record(for: choice)?.name
    }

    /// The custom command picked so far, so the sheet edits it.
    private var customCommand: LocalAgent.Command? {
        if case .custom(let command) = model.selectedAgent { command } else { nil }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.draftDirectory = url }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.selectedDirectory
        if panel.runModal() == .OK { ComposerInput.add(panel.urls, to: &model.draft.attachments) }
    }
}
