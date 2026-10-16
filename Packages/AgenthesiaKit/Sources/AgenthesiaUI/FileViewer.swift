import AgenthesiaCore
import Rendering
import SwiftUI

/// File content only; the window owns loading, selection and viewer controls.
struct FileViewer: View {
    let document: SessionFileDocument
    @State private var showsSource = false

    private var language: CodeLanguage? { CodeLanguage(path: document.url.path(percentEncoded: false)) }

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
                MarkdownPreview(text: document.text)
            } else {
                SourceViewRepresentable(text: document.text, language: language)
                    .accessibilityLabel("File source")
            }
        }
        .onChange(of: document.url) { showsSource = false }
    }
}
