public import SwiftUI

/// The app icon: a sleepy moon under stars, one lit star per live session. The moon wakes while a session
/// needs the user (ADR-0031).
///
/// The Dock tile shows this drawing while sessions run, always in the sky of the Default icon style.
/// `App/AppIcon.icon` (the layers the system composes for the
/// app icon) and `docs/images/logo-*.svg` (README) repeat it as static vector art, so change them together.
public struct AppIcon: View {
    /// Places for stars; sessions beyond them are shown by the Dock badge instead.
    public static let maxStars = 5

    let drawing: Drawing

    /// - Parameters:
    ///   - stars: Lit stars, 0 to `maxStars`.
    ///   - awake: Eyes open, for a session that needs the user.
    public init(stars: Int, awake: Bool = false) {
        drawing = Drawing(stars: max(0, min(stars, Self.maxStars)), awake: awake)
    }

    public var body: some View {
        let drawing = drawing
        Canvas { context, size in drawing.draw(&context, size: size) }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Agenthesia")
    }
}

extension AppIcon {
    /// Values only, so the canvas can draw wherever it likes. Coordinates are in a 100 × 100 box.
    nonisolated struct Drawing: Sendable {
        let stars: Int
        let awake: Bool

        private struct Palette {
            let sky: [Color]
            let moon: [Color]
            let face: Color
            let cheek: Color
            let star: Color
        }

        private static let sky = Palette(
            sky: [rgb(0x9CC9FF), rgb(0x3563D8)],
            moon: [rgb(0xFFF7DA), rgb(0xFFD161)],
            face: rgb(0x7A4B00),
            cheek: rgb(0xFB923C),
            star: .white
        )
        private static func rgb(_ hex: UInt32) -> Color {
            Color(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }

        /// Where the stars sit and how big they are, in the order they light up.
        private static let starSlots: [(x: Double, y: Double, radius: Double)] = [
            (68, 30, 7), (81, 49, 4.6), (54, 19, 4), (83, 22, 3.4), (64, 50, 3),
        ]

        func draw(_ context: inout GraphicsContext, size: CGSize) {
            let palette = Self.sky
            let side = min(size.width, size.height)
            // 824 of 1024 is the body of a macOS icon; the rest is margin for the shadow.
            let body = side * 824 / 1024
            let origin = CGPoint(x: (size.width - body) / 2, y: (size.height - body) / 2)
            let unit = body / 100
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
            func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path {
                Path(
                    ellipseIn: CGRect(
                        x: point(x - rx, y - ry).x,
                        y: point(x - rx, y - ry).y,
                        width: 2 * rx * unit,
                        height: 2 * ry * unit
                    )
                )
            }
            func curve(_ a: (Double, Double), _ control: (Double, Double), _ b: (Double, Double)) -> Path {
                var path = Path()
                path.move(to: point(a.0, a.1))
                path.addQuadCurve(to: point(b.0, b.1), control: point(control.0, control.1))
                return path
            }
            func line(_ a: (Double, Double), _ b: (Double, Double)) -> Path {
                var path = Path()
                path.move(to: point(a.0, a.1))
                path.addLine(to: point(b.0, b.1))
                return path
            }
            func stroke(_ layer: inout GraphicsContext, _ path: Path, _ width: Double) {
                layer.stroke(
                    path,
                    with: .color(palette.face),
                    style: StrokeStyle(lineWidth: width * unit, lineCap: .round)
                )
            }
            func gradient(_ colors: [Color], from top: Double, to bottom: Double) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: colors), startPoint: point(0, top), endPoint: point(0, bottom))
            }

            let tile = RoundedRectangle(cornerRadius: body * 0.225, style: .continuous)
                .path(in: CGRect(origin: origin, size: CGSize(width: body, height: body)))

            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.3), radius: body * 0.025, x: 0, y: body * 0.012))
                layer.fill(tile, with: gradient(palette.sky, from: 0, to: 100))
            }
            context.clip(to: tile)
            context.fill(tile, with: gradient(palette.sky, from: 0, to: 100))

            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.2), radius: 2 * unit, x: 0, y: 2 * unit))
                // A full moon with a bite taken out is a crescent thick enough to hold a face.
                let crescent = ellipse(46, 54, 30, 30).subtracting(ellipse(66, 37, 22, 22))
                layer.fill(crescent, with: gradient(palette.moon, from: 24, to: 84))

                layer.fill(ellipse(29, 65, 3.3, 3.3), with: .color(palette.cheek.opacity(0.5)))
                if awake {
                    layer.fill(ellipse(32.5, 55, 3.6, 4.3), with: .color(palette.face))
                    layer.fill(ellipse(33.9, 53.4, 1.3, 1.3), with: .color(.white))
                    stroke(&layer, curve((27.5, 47.5), (32.5, 44.7), (37.5, 47.5)), 2.2)
                    layer.fill(ellipse(41, 67, 2.4, 2.8), with: .color(palette.face))
                } else {
                    stroke(&layer, curve((27, 54), (32.5, 59), (38, 54)), 3.4)
                    stroke(&layer, line((28.6, 57.6), (27, 60.2)), 2)
                    stroke(&layer, line((32.5, 59.2), (32.5, 62.2)), 2)
                    stroke(&layer, line((36.4, 57.6), (38, 60.2)), 2)
                    stroke(&layer, curve((38, 66.5), (41, 69.3), (44, 66.5)), 2.6)
                }

                for (index, slot) in Self.starSlots.enumerated() {
                    let (x, y, r) = (slot.x, slot.y, slot.radius)
                    var star = Path()
                    star.move(to: point(x, y - r))
                    for (tip, next) in [((x + r, y), (x, y + r)), ((x - r, y), (x, y - r))] {
                        star.addQuadCurve(to: point(tip.0, tip.1), control: point(x, y))
                        star.addQuadCurve(to: point(next.0, next.1), control: point(x, y))
                    }
                    star.closeSubpath()
                    layer.fill(star, with: .color(palette.star.opacity(index < stars ? 1 : 0.13)))
                }
            }

            context.fill(
                tile,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.28), location: 0),
                        .init(color: .white.opacity(0), location: 0.45),
                    ]),
                    startPoint: point(0, 0),
                    endPoint: point(0, 100)
                )
            )
            context.stroke(tile, with: .color(.black.opacity(0.07)), lineWidth: 1.4 * unit)
        }
    }
}
