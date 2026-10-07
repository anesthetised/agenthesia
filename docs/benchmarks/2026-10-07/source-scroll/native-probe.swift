import AppKit
import Darwin
import os

// Standalone diagnostic control: no Agenthesia modules, STTextView, SwiftUI or highlighting.
@MainActor
final class ScrollProbe: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 868, height: 340),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 868, height: 340))
    let text = NSTextView(usingTextLayoutManager: true)
    let signposter = OSSignposter(
        subsystem: "io.github.anesthetised.Agenthesia.ScrollProbe",
        category: .pointsOfInterest
    )
    var link: CADisplayLink?
    var lastDisplay: CFTimeInterval?
    var lastCallback = 0.0
    var start = 0.0
    var maximum = 0.0
    var frames = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        scroll.wantsLayer = true
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        text.frame = scroll.bounds
        text.isEditable = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        scroll.documentView = text
        window.contentView = scroll
        window.title = "Native TextKit 2 scroll control"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        var lines: [String] = []
        for index in 0..<1000 {
            lines += [
                "/// Handles case \(index) of the protocol.",
                "struct Handler\(index): Sendable {",
                "    let name = \"handler-\(index)\"",
                "    var count: Int = \(index)", "",
                "    func process(_ input: [String]) -> Int {",
                "        input.filter { $0.hasPrefix(name) }.count + count  // \(index * 7)",
                "    }", "}", "",
            ]
        }
        text.string = lines.joined(separator: "\n")
        window.contentView?.layoutSubtreeIfNeeded()
        start = ProcessInfo.processInfo.systemUptime
        lastCallback = start
        let link = scroll.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        let callbackInterval = now - lastCallback
        if let lastDisplay {
            let interval = link.timestamp - lastDisplay
            maximum = max(maximum, interval)
            if max(interval, callbackInterval) > 0.05 {
                signposter.emitEvent("LongFrame", "displayMS=\(interval * 1000) callbackMS=\(callbackInterval * 1000)")
            }
        }
        lastDisplay = link.timestamp
        lastCallback = now
        frames += 1
        let clip = scroll.contentView
        let end = max(0, text.frame.height - clip.bounds.height)
        let y = min(clip.bounds.minY + callbackInterval * 7200, end)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        if now - start >= 25 || (y >= end && now - start > 1) {
            let result: [String: Any] = [
                "maxDisplayMS": maximum * 1000, "frames": frames, "elapsedSeconds": now - start,
                "usesTextKit2": text.textLayoutManager != nil, "reachedEnd": y >= end,
                "documentHeight": text.frame.height, "viewportHeight": clip.bounds.height,
                "viewportWidth": clip.bounds.width, "screenMaximumFPS": window.screen?.maximumFramesPerSecond ?? 0,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("PROBE_RESULT=" + String(decoding: data, as: UTF8.self))
            } catch {
                print("PROBE_ERROR=\(error)")
                exit(EXIT_FAILURE)
            }
            link.invalidate()
            NSApp.terminate(nil)
        }
    }
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ScrollProbe()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
