import AppKit
import Testing

@testable import ScrollProbe

@MainActor
@Suite(.serialized)
struct GeometryTests {
    @Test(arguments: ["native", "sttextview"])
    func preservesReservedWidthInActualClipViewport(renderer: String) throws {
        let probe = try ScrollProbe(renderer: renderer, geometry: "source")
        probe.configureWindow()
        defer { probe.window.close() }
        probe.scroll.layoutSubtreeIfNeeded()

        #expect(probe.reservedLeadingWidth > 0)
        #expect(probe.window.contentView?.bounds.size == NSSize(width: 868, height: 340))
        #expect(probe.scroll.frame.minX == probe.reservedLeadingWidth)
        #expect(probe.scroll.contentView.bounds.width + probe.reservedLeadingWidth == 868)
        #expect(probe.scroll.contentView.bounds.height == 340)
        #expect(probe.link == nil)
        #expect(!probe.window.isVisible)
    }

    @Test(arguments: ["native", "sttextview"])
    func retainsFullWidthControl(renderer: String) throws {
        let probe = try ScrollProbe(renderer: renderer, geometry: "full")
        probe.configureWindow()
        defer { probe.window.close() }
        probe.scroll.layoutSubtreeIfNeeded()

        #expect(probe.reservedLeadingWidth == 0)
        #expect(probe.scroll.contentView.bounds.size == NSSize(width: 868, height: 340))
        #expect(probe.link == nil)
        #expect(!probe.window.isVisible)
    }
}
