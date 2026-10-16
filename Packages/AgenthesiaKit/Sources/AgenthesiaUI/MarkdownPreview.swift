import AppKit
import Rendering
import SwiftUI

/// Selectable native Markdown, without web content or automatic resource loading.
struct MarkdownPreview: NSViewRepresentable {
    let text: String

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
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        context.coordinator.update(text, in: textView)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView else { return }
        context.coordinator.update(text, in: textView)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.rendering?.cancel()
    }

    final class Coordinator {
        private var source: String?
        var rendering: Task<Void, Never>?

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
