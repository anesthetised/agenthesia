import AgenthesiaUI
import Foundation

/// Writes the PNGs of the app icon into the asset catalog, from the same drawing the Dock tile uses.
/// Usage: `icon-render <repository root>` (`just icon`).
@MainActor func run() throws {
    guard CommandLine.arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: icon-render <repository root>\n".utf8))
        exit(2)
    }
    let set = URL(filePath: CommandLine.arguments[1]).appending(path: "App/Assets.xcassets/AppIcon.appiconset")
    let icon = AppIcon(stars: 3)
    // The sizes a macOS icon set asks for, as points × scale.
    let slots = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    for (points, scale) in slots {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let data = icon.pngData(pixels: points * scale) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: set.appending(path: name))
        print(name)
    }
}

try run()
