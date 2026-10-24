import AppKit
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct AppIconTests {
    private func bitmap(_ icon: AppIcon, pixels: Int = 128) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: icon.frame(width: Double(pixels), height: Double(pixels)))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// How many pixels differ visibly. Rendering is stable to the eye, not to the byte: the same icon drawn
    /// again may round a few channel values differently, so bytes are not compared.
    private func difference(_ a: AppIcon, _ b: AppIcon) throws -> Int {
        let (left, right) = (try bitmap(a), try bitmap(b))
        var count = 0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide {
                guard let p = left.colorAt(x: x, y: y), let q = right.colorAt(x: x, y: y) else { continue }
                let delta = [
                    p.redComponent - q.redComponent, p.greenComponent - q.greenComponent,
                    p.blueComponent - q.blueComponent, p.alphaComponent - q.alphaComponent,
                ]
                if delta.contains(where: { abs($0) > 0.03 }) { count += 1 }
            }
        }
        return count
    }

    @Test func rendersAtTheRequestedSize() throws {
        let image = try bitmap(AppIcon(stars: 3), pixels: 64)
        #expect(image.pixelsWide == 64 && image.pixelsHigh == 64)
    }

    @Test func theTileLeavesATransparentMarginForTheSystemIconGrid() throws {
        let image = try bitmap(AppIcon(stars: 3))
        // The corner and the middle of the top edge lie in the margin; the centre is the tile.
        #expect(image.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(image.colorAt(x: 64, y: 2)?.alphaComponent ?? 1 < 0.1)
        #expect(image.colorAt(x: 64, y: 64)?.alphaComponent == 1)
    }

    @Test func starsEyesAndStyleChangeTheDrawing() throws {
        let base = AppIcon(stars: 2)
        #expect(try difference(base, AppIcon(stars: 2)) == 0)
        #expect(try difference(base, AppIcon(stars: 3)) > 0)
        #expect(try difference(base, AppIcon(stars: 2, awake: true)) > 0)
        #expect(try difference(base, AppIcon(stars: 2, style: .night)) > 0)
    }

    @Test func starsBeyondTheSlotsAreClamped() throws {
        #expect(try difference(AppIcon(stars: 40), AppIcon(stars: AppIcon.maxStars)) == 0)
        #expect(try difference(AppIcon(stars: -3), AppIcon(stars: 0)) == 0)
        #expect(try difference(AppIcon(stars: AppIcon.maxStars), AppIcon(stars: AppIcon.maxStars - 1)) > 0)
    }

    @Test func theDockTileShowsOneStarPerLiveSessionUpToTheSlots() {
        #expect(DockIconState(live: 0, awake: false).stars == 0)
        #expect(DockIconState(live: 3, awake: false).stars == 3)
        #expect(DockIconState(live: 12, awake: true).stars == AppIcon.maxStars)
        #expect(DockIconState(live: 2, awake: false) != DockIconState(live: 2, awake: true))
    }

    @Test func theDockTileUsesTheNightSkyInDarkMode() throws {
        #expect(AppIcon.Style(try #require(NSAppearance(named: .darkAqua))) == .night)
        #expect(AppIcon.Style(try #require(NSAppearance(named: .aqua))) == .sky)
        // High-contrast variants resolve to their base appearance.
        #expect(AppIcon.Style(try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))) == .night)
        #expect(AppIcon.Style(try #require(NSAppearance(named: .accessibilityHighContrastAqua))) == .sky)
    }
}
