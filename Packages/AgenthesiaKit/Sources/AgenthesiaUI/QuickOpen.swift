import SwiftUI

/// Window-local presentation; indexing and query work belong to the caller.
struct QuickOpen: View {
    @Binding var query: String
    let paths: [String]
    let isLoading: Bool
    let error: String?
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    @State private var selectedPath: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Open").font(.headline)
            TextField("Search files", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search files")
                .focused($searchFocused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) {
                    move(1); return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1); return .handled
                }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            // Background refreshes keep the visible list, so loading is shown only without results.
            if paths.isEmpty {
                Group {
                    if isLoading {
                        ProgressView("Finding files…")
                    } else {
                        ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedPath) {
                        ForEach(paths, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent).lineLimit(1)
                                Text(path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .tag(path)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(path)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: Text("Open file")) { onSelect(path) }
                            .help(path)
                            .onTapGesture(count: 2) { onSelect(path) }
                        }
                    }
                    .accessibilityLabel("Matching files")
                    .onChange(of: selectedPath) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                    .onKeyPress(.return) {
                        openSelection(); return .handled
                    }
                }
            }
            HStack {
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open", action: openSelection).keyboardShortcut(.defaultAction)
                    .disabled(selectedPath == nil)
            }
        }
        .padding()
        .frame(idealWidth: 540, idealHeight: 420)
        .onAppear { searchFocused = true }
        .onChange(of: paths, initial: true) { _, paths in
            selectedPath = Self.retainedSelection(selectedPath, in: paths)
        }
        .onExitCommand(perform: onDismiss)
    }

    private func openSelection() {
        if let selectedPath, paths.contains(selectedPath) { onSelect(selectedPath) }
    }

    private func move(_ offset: Int) {
        selectedPath = Self.movedSelection(selectedPath, by: offset, in: paths)
    }

    /// A refresh keeps a still-listed selection; a new query clears the list first and selects its first match.
    static func retainedSelection(_ selected: String?, in paths: [String]) -> String? {
        if let selected, paths.contains(selected) { selected } else { paths.first }
    }

    static func movedSelection(_ selected: String?, by offset: Int, in paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        guard let selected, let index = paths.firstIndex(of: selected) else { return paths.first }
        return paths[min(max(index + offset, 0), paths.count - 1)]
    }
}
