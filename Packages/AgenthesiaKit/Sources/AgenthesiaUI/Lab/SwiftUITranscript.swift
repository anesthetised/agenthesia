#if DEBUG
    import AppKit
    import Rendering
    import SwiftUI

    /// Prototype C, the control: SwiftUI `Text` views in a `LazyVStack`.
    ///
    /// `Text` takes the rendered text's fonts and colors but not its paragraph styles. Text is selectable within a
    /// message, not across messages.
    final class SwiftUITranscript: TranscriptPrototype {
        let view: NSView
        private let feed = Feed()

        init() {
            view = NSHostingView(rootView: FeedView(feed: feed))
        }

        /// The hosting view's scroll view: SwiftUI's `ScrollView` is an `NSScrollView` on macOS.
        var scrollView: NSScrollView? { Self.firstScrollView(in: view) }

        func show(_ transcript: LabTranscript) {
            feed.transcript = transcript
            feed.count = transcript.count
        }

        func didAppend() {
            feed.count = feed.transcript.count
        }

        func didStream(_ update: StreamingMarkdown.Update) {
            feed.revision += 1
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let scrollView = firstScrollView(in: subview) { return scrollView }
            }
            return nil
        }
    }

    @Observable
    private final class Feed {
        @ObservationIgnored var transcript = LabTranscript(items: [])
        var count = 0
        /// Bumped when the last item streams.
        var revision = 0
    }

    private struct FeedView: View {
        let feed: Feed

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<feed.count, id: \.self) { index in
                        ItemView(feed: feed, index: index)
                    }
                }
                .padding(.horizontal, 12)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    private struct ItemView: View {
        let feed: Feed
        let index: Int

        var body: some View {
            // Only the last item depends on the revision, so only it updates while streaming.
            let _ = index == feed.count - 1 ? feed.revision : 0
            if let card = feed.transcript.card(at: index) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⚙︎ " + card.title).fontWeight(.medium)
                    Text(card.output).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
            } else {
                let text = feed.transcript.text(at: index)
                Text((try? AttributedString(text, including: \.appKit)) ?? AttributedString(text.string))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
#endif
