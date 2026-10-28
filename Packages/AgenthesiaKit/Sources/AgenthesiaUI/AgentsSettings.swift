import ACP
import AgentRuntime
import AgenthesiaCore
import SwiftUI

/// Settings → Agents: installed versions, local agents, Node.js prerequisites and the ACP Registry
/// (ADR-0036, ADR-0037).
struct AgentsSettings: View {
    let catalog: AgentCatalog
    @State private var query = ""
    @State private var confirming: AgentRegistry.Agent?
    @State private var addingCustom = false

    var body: some View {
        Form {
            if !catalog.installations.isEmpty || catalog.installationsMessage != nil {
                Section("Installed") {
                    ForEach(catalog.latest) { installed in
                        InstalledAgentRow(catalog: catalog, newest: installed) { confirming = $0 }
                    }
                    if let message = catalog.installationsMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            localSection
            if catalog.needsNode {
                nodeSection
            }
            registrySection
        }
        .formStyle(.grouped)
        .task { await catalog.refresh() }
        .sheet(isPresented: $addingCustom) { CustomAgentForm(catalog: catalog) }
        .confirmationDialog(
            confirming.map { "Install \($0.name) \($0.version)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { agent in
            Button("Install") { Task { await catalog.install(agent) } }
        } message: { agent in
            Text(Self.installMessage(for: agent))
        }
    }

    private var localSection: some View {
        Section {
            ForEach(catalog.localAgents) { agent in
                LocalAgentRow(catalog: catalog, name: agent.name, command: agent.command) {
                    Button("Remove") { catalog.remove(agent) }
                }
            }
            ForEach(catalog.addable) { found in
                LocalAgentRow(catalog: catalog, name: found.entry.name, command: found.command) {
                    Button("Add") { catalog.add(found) }
                }
            }
            ForEach(catalog.suggestions) { cli in
                AdapterSuggestionRow(catalog: catalog, cli: cli) { confirming = $0 }
            }
            if catalog.localAgents.isEmpty, catalog.found.isEmpty {
                Text("No known ACP agent was found on your PATH.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("On This Mac")
                Spacer()
                Button("Look Again", systemImage: "arrow.clockwise") { Task { await catalog.discover(refresh: true) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Look again with a fresh login-shell PATH")
                Button("Add Custom…") { addingCustom = true }
                    .buttonStyle(.borderless)
            }
        } footer: {
            Text(
                "Agenthesia looks for known ACP agents on your login shell's PATH without running them. Check starts a command briefly in an empty folder to ask whether it speaks ACP; it does not sign in."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nodeSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                switch catalog.node {
                case .unknown:
                    Text("Not checked yet").foregroundStyle(.secondary)
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                case .ready(let toolchain):
                    Label(
                        "Node.js \(toolchain.nodeVersion) and npm \(toolchain.npmVersion)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .help(toolchain.node)
                case .unavailable(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Check Again") { Task { await catalog.checkAgain() } }
                    .disabled(catalog.node == .checking)
            }
        } header: {
            Text("Node.js and npm")
        } footer: {
            Text(
                "npm agents run with the Node.js and npm from your login shell. Agenthesia does not install or change them; after installing or switching Node.js, use Check Again."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var registrySection: some View {
        Section {
            TextField("Search", text: $query, prompt: Text("Search agents"))
            if let message = catalog.registryMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if catalog.registry == nil, catalog.isRefreshing {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(Self.filter(catalog.registry?.catalog.agents ?? [], query: query)) { agent in
                RegistryAgentRow(catalog: catalog, agent: agent) { confirming = agent }
            }
        } header: {
            HStack {
                Text("ACP Registry")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(catalog.isRefreshing)
            }
        } footer: {
            if let snapshot = catalog.registry {
                Text("Updated \(snapshot.validatedAt, format: .relative(presentation: .named)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Agents whose name, ID or description contains the query, in registry order.
    static func filter(_ agents: [AgentRegistry.Agent], query: String) -> [AgentRegistry.Agent] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
                || $0.description.localizedStandardContains(query)
        }
    }

    /// What installation does, where the agent comes from and under which license, before it is installed.
    static func installMessage(for agent: AgentRegistry.Agent) -> String {
        let source = agent.repository ?? agent.website
        var lines = [
            "\(agent.name) is a separate program\(source.map { " from \($0.absoluteString)" } ?? ""), "
                + "distributed under \(agent.license.map { "the \($0) license" } ?? "a license the registry does not state"). "
                + "It runs with your permissions and is not part of Agenthesia."
        ]
        switch agent.installation() {
        case .binary(let binary):
            lines.append(
                "Agenthesia downloads \(binary.archive.absoluteString)"
                    + (binary.sha256 == nil ? ". The registry declares no checksum." : " and verifies its checksum.")
            )
        case .npm(let package):
            lines.append(
                "npm installs \(package.package) and its dependencies with your Node.js, with install scripts disabled."
            )
        case .unsupported:
            break
        }
        return lines.joined(separator: "\n\n")
    }

    /// The command as a shell would show it, quoting words with spaces or quotes.
    static func commandLine(_ command: LocalAgent.Command) -> String {
        ([command.executable] + command.arguments).map { word in
            word.isEmpty || word.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) })
                ? "'" + word.replacing("'", with: "'\\''") + "'" : word
        }.joined(separator: " ")
    }

    /// What a passed initialize probe learned. It says nothing about whether the user is signed in.
    static func summary(of profile: ACP.AgentProfile) -> String {
        var parts = ["Speaks ACP v\(profile.protocolVersion)"]
        if let info = profile.info {
            parts.append("\(info.title ?? info.name) \(info.version)")
        }
        switch profile.authMethods.count {
        case 0: parts.append("no sign-in methods")
        case 1: parts.append("1 sign-in method")
        case let count: parts.append("\(count) sign-in methods")
        }
        return parts.joined(separator: " · ")
    }

    /// How the registry distributes the agent for this Mac, or why it cannot be installed.
    static func distribution(of agent: AgentRegistry.Agent) -> String {
        switch agent.installation() {
        case .binary: "Binary for this Mac"
        case .npm(let package): "npm package \(package.package)"
        case .unsupported(.uvx): "Requires uv (uvx), which Agenthesia does not support yet"
        case .unsupported(.noCompatibleDistribution): "No distribution for this Mac"
        }
    }
}

private struct InstalledAgentRow: View {
    let catalog: AgentCatalog
    let newest: AgentInstallation
    let update: (AgentRegistry.Agent) -> Void

    private var versions: [AgentInstallation] { catalog.versions(of: newest.agentID) }
    private var available: AgentRegistry.Agent? {
        catalog.registry?.catalog.agents.first { $0.id == newest.agentID && catalog.hasUpdate($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(newest.name)
                    Text(versions.map(\.version).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Installed versions: \(versions.map(\.version).joined(separator: ", "))")
                }
                Spacer()
                if let operation = catalog.operations[newest.agentID] {
                    OperationProgress(catalog: catalog, agentID: newest.agentID, operation: operation)
                } else {
                    if let available {
                        Button("Update to \(available.version)…") { update(available) }
                    }
                    Menu("Remove") {
                        ForEach(versions) { version in
                            Button("Remove \(version.version)") { Task { await catalog.remove(version) } }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
            if let failure = catalog.failures[newest.agentID] {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct RegistryAgentRow: View {
    let catalog: AgentCatalog
    let agent: AgentRegistry.Agent
    let install: () -> Void

    private var installed: Bool { catalog.versions(of: agent.id).contains { $0.version == agent.version } }
    private var supported: Bool {
        if case .unsupported = agent.installation() { false } else { true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(agent.name) \(agent.version)")
                    Text(agent.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(AgentsSettings.distribution(of: agent))
                        if let license = agent.license {
                            Text("·").accessibilityHidden(true)
                            Text(license)
                        }
                        if let source = agent.repository ?? agent.website {
                            Text("·").accessibilityHidden(true)
                            Link("Source", destination: source)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let operation = catalog.operations[agent.id] {
                    OperationProgress(catalog: catalog, agentID: agent.id, operation: operation)
                } else if installed {
                    Text("Installed").foregroundStyle(.secondary)
                } else if supported {
                    Button(catalog.versions(of: agent.id).isEmpty ? "Install…" : "Update…", action: install)
                }
            }
            if let failure = catalog.failures[agent.id], catalog.versions(of: agent.id).isEmpty {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct OperationProgress: View {
    let catalog: AgentCatalog
    let agentID: String
    let operation: AgentCatalog.Operation

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            switch operation {
            case .installing(let version):
                Text("Installing \(version)…").foregroundStyle(.secondary)
                Button("Cancel") { catalog.cancel(agentID) }
            case .removing:
                Text("Removing…").foregroundStyle(.secondary)
            }
        }
    }
}

/// A local agent or a found command: its command line, Check and the last result.
private struct LocalAgentRow<Actions: View>: View {
    let catalog: AgentCatalog
    let name: String
    let command: LocalAgent.Command
    @ViewBuilder let actions: Actions

    private var check: AgentCatalog.Check? { catalog.checks[command] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(AgentsSettings.commandLine(command))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if check == .checking {
                    ProgressView().controlSize(.small)
                }
                Button("Check") { Task { await catalog.check(command) } }
                    .disabled(check == .checking)
                actions
            }
            switch check {
            case .passed(let profile):
                Label(AgentsSettings.summary(of: profile), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            case .checking, nil:
                EmptyView()
            }
        }
    }
}

/// An ordinary CLI that needs a registry adapter to speak ACP.
private struct AdapterSuggestionRow: View {
    let catalog: AgentCatalog
    let cli: LocalAgentDiscovery.Found
    let install: (AgentRegistry.Agent) -> Void

    private var adapter: AgentRegistry.Agent? {
        catalog.registry?.catalog.agents.first { $0.id == cli.entry.adapterID }
    }
    private var adapterName: String {
        adapter?.name ?? LocalAgentDiscovery.known.first { $0.registryID == cli.entry.adapterID }?.name ?? "ACP"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cli.entry.name)
                    Text(cli.path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let adapter, catalog.operations[adapter.id] == nil {
                    Button("Install \(adapter.name)…") { install(adapter) }
                }
            }
            Text(
                "\(cli.entry.name) does not speak ACP by itself; it needs the \(adapterName) adapter from the ACP Registry."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Adds any command as a local agent.
private struct CustomAgentForm: View {
    let catalog: AgentCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""

    private var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Executable", text: $executable, prompt: Text("/path/to/agent or command on PATH"))
                    TextField("Arguments", text: $arguments, axis: .vertical).lineLimit(2...5)
                } header: {
                    Text("Add Custom Agent")
                } footer: {
                    Text("One argument per line. The command must speak ACP over standard input and output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func add() {
        let command = RootView.launchCommand(executable: executable, arguments: arguments)
        catalog.addCustom(
            name: name.trimmingCharacters(in: .whitespaces),
            executable: command.executable,
            arguments: command.arguments
        )
        dismiss()
    }
}
