import AgenthesiaCore
import AppKit
import Rendering
import SwiftUI

/// Selectable native Markdown, without web content or automatic resource loading.
struct MarkdownPreview: NSViewRepresentable {
    let text: String
    /// The previewed file's directory, against which relative links resolve.
    let directory: URL
    /// The session's root, which links must stay inside; without it no link opens a file.
    let root: URL?
    /// Opens a file in the pane, as a path relative to `root`.
    let onOpenPath: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.setAccessibilityLabel("Markdown preview")
        textView.delegate = context.coordinator
        context.coordinator.configure(directory: directory, root: root, openPath: onOpenPath)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        context.coordinator.update(text, in: textView)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView else { return }
        context.coordinator.configure(directory: directory, root: root, openPath: onOpenPath)
        context.coordinator.update(text, in: textView)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.rendering?.cancel()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private var source: String?
        var rendering: Task<Void, Never>?
        private var directory = URL(filePath: "/")
        private var root: URL?
        private var openPath: (String) -> Void = { _ in }

        func configure(directory: URL, root: URL?, openPath: @escaping (String) -> Void) {
            self.directory = directory
            self.root = root
            self.openPath = openPath
        }

        /// Every click is handled here, so a link AppKit cannot open never reaches `NSWorkspace` and its alert.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }), let root else {
                return true
            }
            LinkTarget(url, base: directory, root: root).follow(openFile: openPath)
            return true
        }

        func update(_ source: String, in view: NSTextView) {
            guard self.source != source else { return }
            self.source = source
            rendering?.cancel()
            view.string = ""
            let renderer = MarkdownRenderer()
            rendering = Task { [weak view] in
                // Construct off the main actor, then transfer the complete attributed string once.
                let rendered: NSAttributedString = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: renderer.render(source))
                    }
                }
                guard !Task.isCancelled, let view else { return }
                view.textStorage?.setAttributedString(rendered)
                view.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }
}
