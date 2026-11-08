import AgenthesiaCore
import AppKit
import SwiftUI

/// A window without a session (ADR-0040): the heading with the project's menu, the switch to a draft without a project
/// (ADR-0048) and, under them, the composer card with the agent and checkout above the text. Send starts the session
/// with the draft as its first message.
struct SessionDraftView: View {
    @Bindable var model: SessionWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set while the draft leaves after Send: the card moves to the bottom edge, where the session's composer sits.
    @Environment(\.draftLeaving) private var leaving
    @State private var checkout: DraftCheckout?
    @State private var editingCommand = false
    @State private var catalogLoaded = false

    /// Shown once the catalog has loaded, so the editor does not flicker away while installations are read.
    private var needsAgent: Bool { catalogLoaded && model.draftNeedsAgent }

    /// The pills' tooltip and accessibility note: what they show is a cached hint, not a session's confirmed value.
    static let hintNote = "Last used with this agent; confirmed when the session starts"

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                heading
                projectSwitch
            }
            .opacity(leaving ? 0 : 1)
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.draftError {
                    FailureBanner(error, offering: [.manageAgents], perform: { _ in })
                }
                card
            }
            .frame(maxWidth: TranscriptColumn.maxWidth)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leaving ? .bottom : .center)
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

    /// `What should we build in <project>?`, the project on a line of its own when the column is too narrow.
    private var heading: some View {
        let heading = DraftHeading(project: model.draftProjectName, withoutProject: model.draftWithoutProject)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) { headingParts(heading) }
            VStack(spacing: 4) { headingParts(heading) }
        }
        .font(.largeTitle).lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func headingParts(_ heading: DraftHeading) -> some View {
        if let lead = heading.lead { Text(lead) }
        if let menu = heading.menu {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                projectMenu(menu)
                Text(heading.end)
            }
        }
    }

    /// `or start without a project`, or `in a project` back; per draft (ADR-0048).
    private var projectSwitch: some View {
        let heading = DraftHeading(project: model.draftProjectName, withoutProject: model.draftWithoutProject)
        return Button(heading.alternative, action: toggleProject)
            .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
    }

    private func toggleProject() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { model.draftWithoutProject.toggle() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                agentMenu
                if let checkout, !model.draftWithoutProject {
                    Label(checkout.title, systemImage: checkout == .folder ? "folder" : "arrow.triangle.branch")
                        .foregroundStyle(.secondary).lineLimit(1).help(checkout.help)
                }
                Spacer(minLength: 0)
            }
            if needsAgent {
                VStack(spacing: 10) {
                    Text("Add an agent to start a session.").foregroundStyle(.secondary)
                    ManageAgentsButton(title: "Add Agent…").buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ComposerInput(
                    text: $model.draft.text,
                    attachments: $model.draft.attachments,
                    commands: [],
                    isEnabled: true,
                    onSubmit: { _ in send() }
                )
                bottomRow
            }
        }
        .padding(12)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !needsAgent else { return false }
            ComposerInput.add(urls, to: &model.draft.attachments)
            return true
        }
    }

    /// Attach, the hint pills and Send, under the text.
    private var bottomRow: some View {
        HStack(spacing: 8) {
            Button("Attach Files…", systemImage: "paperclip", action: chooseAttachments)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Attach files or folders (⇧⌘A)")
            hintPills.frame(maxWidth: .infinity, alignment: .leading)
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly).buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .help("Start the session with this message (Return)")
                .disabled(!model.canStartDraft)
        }
    }

    /// The agent's cached mode, model and effort (ADR-0040) in the session's control row: hints, so drawn as secondary
    /// and worded as such. A mode reads `Default mode` until one is picked, because only a picked mode is applied.
    private var hintPills: some View {
        ConfigControlRow(
            options: model.draftPills,
            selected: model.draftValue(of:),
            placeholder: "Default mode",
            note: Self.hintNote
        ) { id, value in
            if case .select(let value) = value { model.draftConfig[id] = value }
        }
        // A borderless menu draws its title in the control's color whatever the foreground style says.
        .opacity(0.6)
    }

    /// The project as a borderless menu in the heading: known projects, most recently used first, and Choose Folder….
    private func projectMenu(_ title: String) -> some View {
        let selected = model.selectedDirectory
        let projects = model.recentProjects
        return Menu {
            ForEach(projects) { project in
                Button {
                    model.draftDirectory = URL(filePath: project.rootPath, directoryHint: .isDirectory)
                } label: {
                    if model.isDraftProject(project) {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            if !projects.isEmpty { Divider() }
            Button("Choose Folder…", action: chooseFolder)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).foregroundStyle(.tint).truncationMode(.middle)
                // Hidden, or it reads as a second project menu.
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Project: \(model.draftProjectName ?? "none")")
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
            // The card's Add Agent… is the way to Settings while there is no agent.
            if !needsAgent { ManageAgentsButton() }
        } label: {
            Label {
                Text(selected.flatMap(agentName) ?? "Choose Agent")
            } icon: {
                // The pop-up button takes its description from the symbol's image, which would otherwise say `CPU chip`.
                Image(nsImage: NSImage(systemSymbolName: "cpu", accessibilityDescription: agentLabel) ?? NSImage())
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel(agentLabel)
        .help("The agent that starts the session")
    }

    private var agentLabel: String { "Agent: \(model.selectedAgent.flatMap(agentName) ?? "none")" }

    private func agentName(_ choice: AgentCatalog.Choice) -> String? {
        model.catalog?.name(of: choice) ?? model.record(for: choice)?.name
    }

    /// The custom command picked so far, so the sheet edits it.
    private var customCommand: LocalAgent.Command? {
        if case .custom(let command) = model.selectedAgent { command } else { nil }
    }

    /// Send, with the card moving to the bottom edge as the draft gives way to the session (none under Reduce Motion).
    private func send() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { model.startDraft() }
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
