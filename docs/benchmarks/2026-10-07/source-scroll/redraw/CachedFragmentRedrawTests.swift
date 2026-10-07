#if os(macOS)
    import AppKit
    import Testing
    @testable import STTextViewAppKit

    @Suite(.serialized)
    @MainActor
    struct CachedFragmentRedrawTests {
        private func needsDisplay(_ view: NSView) -> Bool {
            view.needsDisplay || (view.layer?.needsDisplay() ?? false)
        }

        private func withView(_ body: (STTextView, STTextLayoutFragmentView) throws -> Void) throws {
            let scroll = STTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let view = try #require(scroll.documentView as? STTextView)
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            view.setString("Hello world\nSecond line\n")
            scroll.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            let fragment = try #require(
                view.contentViewportView.subviews.compactMap { $0 as? STTextLayoutFragmentView }.first {
                    $0.layoutFragment.textLineFragments.first?.attributedString.string.contains("Hello") == true
                }
            )
            window.displayIfNeeded()
            fragment.layer?.displayIfNeeded()
            fragment.needsLayout = false
            fragment.needsDisplay = false
            try #require(!needsDisplay(fragment))
            try body(view, fragment)
        }

        @Test func unchangedCachedFragmentDoesNotInvalidate() throws {
            try withView { view, fragment in
                view.textViewportLayoutController(
                    view.textLayoutManager.textViewportLayoutController,
                    configureRenderingSurfaceFor: fragment.layoutFragment
                )
                #expect(!needsDisplay(fragment))
                #expect(!fragment.needsLayout)
            }
        }

        @Test func renderingAttributeChangeInvalidatesCachedFragment() throws {
            try withView { view, fragment in
                view.addRenderingAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 5))
                view.layoutSubtreeIfNeeded()
                let current = try #require(view.fragmentViewMap.object(forKey: fragment.layoutFragment))
                #expect(needsDisplay(current), "A reused rendering surface must redraw changed temporary attributes")
                current.layer?.displayIfNeeded()
                current.needsDisplay = false
                try #require(!needsDisplay(current))
                view.removeRenderingAttribute(.foregroundColor, range: NSRange(location: 0, length: 5))
                view.layoutSubtreeIfNeeded()
                #expect(needsDisplay(current), "Removing temporary attributes must also redraw")
            }
        }

        @Test func persistentColorChangeReachesRenderingSurface() throws {
            try withView { view, _ in
                view.addAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 5))
                view.layoutSubtreeIfNeeded()
                let current = try #require(
                    view.contentViewportView.subviews.compactMap { $0 as? STTextLayoutFragmentView }.first {
                        $0.layoutFragment.textLineFragments.first?.attributedString.string.contains("Hello") == true
                    }
                )
                let line = try #require(current.layoutFragment.textLineFragments.first)
                #expect(
                    line.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red
                )
                #expect(needsDisplay(current))
            }
        }

        @Test func textChangeReachesRenderingSurface() throws {
            try withView { view, _ in
                view.setString("Changed text\nSecond line\n")
                view.layoutSubtreeIfNeeded()
                let current = try #require(
                    view.contentViewportView.subviews.compactMap { $0 as? STTextLayoutFragmentView }.first {
                        $0.layoutFragment.textLineFragments.first?.attributedString.string.contains("Changed text")
                            == true
                    }
                )
                #expect(needsDisplay(current))
            }
        }
    }
#endif
