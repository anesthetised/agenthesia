import AgenthesiaCore
import AppKit
import Rendering
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor
@Suite struct FileViewerTests {
    @Test func markdownPreviewRendersSelectableReadOnlyText() async throws {
        let textView = NSTextView(usingTextLayoutManager: true)
        let coordinator = MarkdownPreview.Coordinator()
        coordinator.update("# Heading\n\n**bold** and `code`", in: textView)
        await coordinator.rendering?.value
        #expect(textView.string == "Heading\nbold and code")
        let range = (textView.string as NSString).range(of: "bold")
        let font = try #require(
            textView.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        )
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test func latestMarkdownRenderWinsAndEqualSourcePreservesSelection() async {
        let textView = NSTextView(usingTextLayoutManager: true)
        let coordinator = MarkdownPreview.Coordinator()
        coordinator.update(String(repeating: "# Old\n\n", count: 100), in: textView)
        let old = coordinator.rendering
        coordinator.update("Latest **text**", in: textView)
        await coordinator.rendering?.value
        await old?.value
        #expect(textView.string == "Latest text")
        textView.setSelectedRange(NSRange(location: 7, length: 4))
        coordinator.update("Latest **text**", in: textView)
        #expect(textView.selectedRange() == NSRange(location: 7, length: 4))
    }

    private func descendant<V: NSView>(of type: V.Type, in root: NSView) -> V? {
        if let match = root as? V { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    @Test func previewIsSelectableReadOnlyAndAccessible() {
        let host = NSHostingView(rootView: MarkdownPreview(text: "# Heading"))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        let text = descendant(of: NSTextView.self, in: host)
        #expect(text?.isEditable == false)
        #expect(text?.isSelectable == true)
        #expect(text?.accessibilityLabel() == "Markdown preview")
    }

    private func descendants<V: NSView>(of type: V.Type, in root: NSView) -> [V] {
        ((root as? V).map { [$0] } ?? []) + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    /// Window-coordinate spans of every split view's panes, e.g. to compare layouts across macOS versions.
    private func layout(of host: NSView, window: NSWindow) -> String {
        let span: (NSView) -> String = {
            let frame = $0.convert($0.bounds, to: nil)
            return "\(frame.minX)–\(frame.maxX)"
        }
        let splits = descendants(of: NSSplitView.self, in: host).map {
            $0.arrangedSubviews.map(span).joined(separator: " | ")
        }
        return "window \(window.contentLayoutRect.width) pt; splits: \(splits.joined(separator: "; "))"
    }

    private func expectHorizontallyContained(_ view: NSView, in host: NSView, window: NSWindow) {
        // Nested native split dividers can round the trailing edge by one point.
        let tolerance: CGFloat = 1
        let layout = "\(type(of: view)) in \(layout(of: host, window: window))"
        let inHost = host.convert(view.bounds, from: view)
        #expect(inHost.minX >= host.bounds.minX - tolerance, "\(layout)")
        #expect(inHost.maxX <= host.bounds.maxX + tolerance, "\(layout)")
        let inWindow = view.convert(view.bounds, to: nil)
        #expect(inWindow.minX >= window.contentLayoutRect.minX - tolerance, "\(layout)")
        #expect(inWindow.maxX <= window.contentLayoutRect.maxX + tolerance, "\(layout)")
    }

    @Test func switchesMarkdownPreviewAndSourceInSplitPane() async throws {
        let content = "# Heading\n\n" + String(repeating: "A paragraph with **bold** text and `code`.\n\n", count: 40)
        let document = SessionFileDocument(url: URL(filePath: "/workspace/README.md"), text: content)
        let transcript = DemoSession()
        let host = NSHostingView(
            rootView: NavigationSplitView {
                List { Text("Saved session") }.navigationSplitViewColumnWidth(min: 200, ideal: 240)
            } detail: {
                HSplitView {
                    VStack {
                        DemoTranscript(session: transcript).frame(maxWidth: .infinity, maxHeight: .infinity)
                        ComposerInput(
                            text: .constant(""),
                            attachments: .constant([]),
                            commands: [],
                            isEnabled: false,
                            onSubmit: { _ in }
                        )
                        HStack {
                            Text("Saved history · read-only"); Spacer(); Button("Continue") {}
                        }
                    }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        HStack {
                            Text("README.md").font(.headline).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Reload File", systemImage: "arrow.clockwise") {}.labelStyle(.iconOnly)
                            Button("Close File", systemImage: "xmark") {}.labelStyle(.iconOnly)
                        }.padding(8)
                        Divider()
                        FileViewer(document: document)
                    }.frame(minWidth: 240, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minWidth: 740, minHeight: 500)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 552),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "FileViewerTestToolbar")
        window.toolbarStyle = .unified
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let picker = try #require(descendant(of: NSSegmentedControl.self, in: host))
        for iteration in 0..<6 {
            window.setContentSize(NSSize(width: [740.0, 900, 1000][iteration / 2], height: 552))
            picker.selectedSegment = iteration.isMultiple(of: 2) ? 1 : 0
            _ = picker.sendAction(picker.action, to: picker.target)
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(10))
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
            }
            // CI runs an older macOS than development machines; keep its layout in the log.
            if ProcessInfo.processInfo.environment["CI"] != nil {
                print("FileViewerTests layout: \(layout(of: host, window: window))")
            }
            if iteration.isMultiple(of: 2) {
                let source = try #require(descendant(of: SourceView.self, in: host))
                #expect(source.text == content)
                #expect(source.bounds.width.isFinite && source.bounds.width > 0)
                #expect(source.bounds.height.isFinite && source.bounds.height > 0)
                #expect(source.bounds.width <= window.contentLayoutRect.width)
                #expect(source.bounds.height <= window.contentLayoutRect.height)
                expectHorizontallyContained(source, in: host, window: window)
            } else {
                #expect(descendant(of: SourceView.self, in: host) == nil)
                let preview = try #require(
                    descendants(of: NSTextView.self, in: host).first {
                        $0.accessibilityLabel() == "Markdown preview"
                    }
                )
                #expect(preview.isEditable == false)
                let viewport = try #require(preview.enclosingScrollView)
                expectHorizontallyContained(viewport, in: host, window: window)
            }
            expectHorizontallyContained(picker, in: host, window: window)
        }
    }

    @Test func sourceViewportFillsFiniteProposalDespiteLongLines() throws {
        let host = NSHostingView(
            rootView:
                SourceViewRepresentable(text: String(repeating: "long source ", count: 1000), language: nil)
                .frame(width: 320, height: 240)
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let source = try #require(descendant(of: SourceView.self, in: host))
        #expect(abs(source.bounds.width - 320) < 0.5)
        #expect(abs(source.bounds.height - 240) < 0.5)
    }

    @Test func sourceViewerIsHostedForUnknownLanguages() {
        let document = SessionFileDocument(url: URL(filePath: "/workspace/file.unknown"), text: "plain text")
        let host = NSHostingView(rootView: FileViewer(document: document))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        let source = descendant(of: SourceView.self, in: host)
        #expect(source?.text == "plain text")
        #expect(source?.language == nil)
        #expect(source?.textView.isEditable == false)
    }

    @Test func linkedLineSelectsInSourceAndMarkdownOpensSource() throws {
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let code = SessionFileDocument(url: URL(filePath: "/workspace/a.unknown"), text: text)
        let host = NSHostingView(rootView: FileViewer(document: code, line: 120))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        host.layoutSubtreeIfNeeded()
        let source = try #require(descendant(of: SourceView.self, in: host))
        #expect((source.text as NSString).substring(with: source.textView.textSelection) == "line 120")

        let markdown = SessionFileDocument(url: URL(filePath: "/workspace/README.md"), text: text)
        #expect(FileViewer.opensSource(markdown, line: 3))
        #expect(!FileViewer.opensSource(markdown, line: nil))
        #expect(!FileViewer.opensSource(code, line: 3))
        let markdownHost = NSHostingView(rootView: FileViewer(document: markdown, line: 3))
        markdownHost.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        markdownHost.layoutSubtreeIfNeeded()
        #expect(descendant(of: SourceView.self, in: markdownHost)?.text == text)
        let plain = NSHostingView(rootView: FileViewer(document: markdown))
        plain.frame = markdownHost.frame
        plain.layoutSubtreeIfNeeded()
        #expect(descendant(of: SourceView.self, in: plain) == nil)
    }
}
