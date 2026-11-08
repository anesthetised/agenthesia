import AgenthesiaCore
import Rendering
import SwiftUI

/// File content only; the window owns loading, selection and viewer controls.
struct FileViewer: View {
    let document: SessionFileDocument
    /// A line from a transcript link. Markdown has lines only in its source.
    let line: Int?
    /// The session's root and how to open a file of it, for the links of a Markdown preview.
    let root: URL?
    let onOpenPath: (String) -> Void
    @State private var showsSource: Bool

    init(
        document: SessionFileDocument,
        line: Int? = nil,
        root: URL? = nil,
        onOpenPath: @escaping (String) -> Void = { _ in }
    ) {
        self.document = document
        self.line = line
        self.root = root
        self.onOpenPath = onOpenPath
        _showsSource = State(initialValue: Self.opensSource(document, line: line))
    }

    private var language: CodeLanguage? { Self.language(of: document) }

    private static func language(of document: SessionFileDocument) -> CodeLanguage? {
        CodeLanguage(path: document.url.path(percentEncoded: false))
    }

    static func opensSource(_ document: SessionFileDocument, line: Int?) -> Bool {
        line != nil && language(of: document) == .markdown
    }

    var body: some View {
        VStack(spacing: 0) {
            if language == .markdown {
                Picker("Markdown display", selection: $showsSource) {
                    Text("Preview").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(8)
                Divider()
            }
            if language == .markdown && !showsSource {
                MarkdownPreview(
                    text: document.text,
                    directory: document.url.deletingLastPathComponent(),
                    root: root,
                    onOpenPath: onOpenPath
                )
            } else {
                SourceViewRepresentable(text: document.text, language: language, line: line)
                    .accessibilityLabel("File source")
            }
        }
        .onChange(of: document.url) { showsSource = Self.opensSource(document, line: line) }
    }
}
