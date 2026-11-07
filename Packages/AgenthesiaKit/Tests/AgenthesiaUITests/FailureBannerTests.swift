import AgenthesiaCore
import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct FailureBannerTests {
    private let unknown = "RPCError(code: -32002, message: \"Unknown session\", data: nil)"

    private func banner(_ stored: String, offering: Set<SessionFailure.Action> = []) -> FailureBanner {
        FailureBanner(stored, offering: offering, perform: { _ in })
    }

    @Test func onlyTheOfferedActionsShow() {
        #expect(banner(unknown, offering: [.newSession, .agentLog]).actions == [.newSession])
        #expect(banner(unknown, offering: [.agentLog, .manageAgents]).actions.isEmpty)
        #expect(banner("closed", offering: [.agentLog, .newSession]).actions == [.agentLog])
        #expect(banner("closed").actions.isEmpty)
    }

    @Test func aLongErrorStaysInsideTheTranscriptColumn() async throws {
        let width: CGFloat = 1400
        let long =
            "RPCError(code: -32603, message: \"" + String(repeating: "model overloaded ", count: 40)
            + "\", data: nil)"
        let host = NSHostingView(rootView: banner(long, offering: [.agentLog]))
        host.frame = .init(x: 0, y: 0, width: width, height: 400)
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // The summary is red; its horizontal extent is the text's.
        var columns = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 { columns.insert(x) }
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / width
        let low = try #require(columns.min()), high = try #require(columns.max())
        let left = CGFloat(low) / scale, right = CGFloat(high) / scale
        let margin = (width - TranscriptColumn.maxWidth) / 2
        #expect(left >= margin - 1 && right <= width - margin + 1)
        // The text wraps at the column rather than being short.
        #expect(right - left > TranscriptColumn.maxWidth * 0.6)
    }
}
