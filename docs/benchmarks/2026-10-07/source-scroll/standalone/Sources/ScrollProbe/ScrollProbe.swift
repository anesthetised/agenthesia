import AppKit
import CryptoKit
import Darwin
import STTextViewAppKit
import os

// Both controls use this runner in fresh processes. Neither constructs Agenthesia or SwiftUI views.
@MainActor
final class ScrollProbe: NSObject, NSApplicationDelegate {
    let renderer: String
    let geometry: String
    let reservedLeadingWidth: CGFloat
    let fixture: String
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 868, height: 340),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 868, height: 340))
    let document: NSView
    let layoutManager: NSTextLayoutManager
    let signposter = OSSignposter(
        subsystem: "io.github.anesthetised.Agenthesia.StandaloneScrollProbe",
        category: .pointsOfInterest
    )
    var link: CADisplayLink?
    var signpost: OSSignpostIntervalState?
    var lastDisplay: CFTimeInterval?
    var lastCallback: Double?
    var start: Double?
    var previousScroll = 0.0
    var setupMS = 0.0
    var firstLineHeight: CGFloat = 0
    var done = false
    var timedOut = false
    var displayIntervals: [Double] = []
    var callbackIntervals: [Double] = []
    var longFrames: [[String: Double]] = []

    init(renderer: String, geometry: String) throws {
        self.renderer = renderer
        self.geometry = geometry
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        // SourceView retains its hidden 5-digit gutter width for this 10,000-line fixture.
        reservedLeadingWidth =
            geometry == "source"
            ? (5 * ("0" as NSString).size(withAttributes: [.font: font]).width + 16).rounded(.up) : 0
        if renderer == "sttextview" {
            let text = STTextView()
            text.isEditable = false
            text.highlightSelectedLine = false
            text.font = font
            text.textColor = .labelColor
            document = text
            layoutManager = text.textLayoutManager
        } else {
            let text = NSTextView(usingTextLayoutManager: true)
            text.isEditable = false
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = true
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.heightTracksTextView = false
            text.textContainer?.containerSize = text.maxSize
            text.textContainerInset = .zero
            text.font = font
            text.textColor = .labelColor
            guard let manager = text.textLayoutManager else {
                throw CocoaError(.featureUnsupported)
            }
            document = text
            layoutManager = manager
        }
        // Exact copy of TranscriptGenerator.swiftFile(lines: 10_000); hash is included in results.
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
        fixture = lines.joined(separator: "\n")
        super.init()
    }

    // Configure geometry without activating a window or starting measurement, also used by integration tests.
    func configureWindow() {
        scroll.clipsToBounds = true
        scroll.wantsLayer = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let host = NSView(frame: scroll.frame)
        scroll.frame.origin.x = reservedLeadingWidth
        scroll.frame.size.width -= reservedLeadingWidth
        document.frame = scroll.bounds
        scroll.documentView = document
        window.isReleasedWhenClosed = false
        if geometry == "source" {
            host.addSubview(scroll)
            window.contentView = host
        } else {
            window.contentView = scroll
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()
        window.title = "Standalone \(renderer) scroll control"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        signpost = signposter.beginInterval("Scenario", "\(self.renderer)")
        let link = scroll.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastDisplay, let lastCallback {
            let displayMS = (link.timestamp - lastDisplay) * 1000
            let callbackMS = (now - lastCallback) * 1000
            displayIntervals.append(displayMS)
            callbackIntervals.append(callbackMS)
            if max(displayMS, callbackMS) > 50 {
                signposter.emitEvent("LongFrame", "displayMS=\(displayMS) callbackMS=\(callbackMS)")
                longFrames.append([
                    "elapsedSeconds": now - (start ?? now), "displayMS": displayMS, "callbackMS": callbackMS,
                ])
            }
        }
        lastDisplay = link.timestamp
        lastCallback = now
        if done {
            finish(now: now)
            return
        }
        guard let start else {
            self.start = now
            if let text = document as? STTextView { text.text = fixture }
            if let text = document as? NSTextView { text.string = fixture }
            scroll.layoutSubtreeIfNeeded()
            document.layoutSubtreeIfNeeded()
            firstLineHeight =
                layoutManager.textLayoutFragment(for: layoutManager.documentRange.location)?
                .textLineFragments.first?.typographicBounds.height ?? 0
            previousScroll = ProcessInfo.processInfo.systemUptime
            setupMS = (previousScroll - now) * 1000
            return
        }
        let clip = scroll.contentView
        let end = max(0, document.frame.height - clip.bounds.height)
        let y = min(clip.bounds.minY + (now - previousScroll) * 7200, end)
        previousScroll = now
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        timedOut = now - start >= 25
        done = y >= end || timedOut
    }

    func finish(now: Double) {
        link?.invalidate()
        if let signpost { signposter.endInterval("Scenario", signpost) }
        let clip = scroll.contentView
        var load = 0.0
        _ = getloadavg(&load, 1)
        let result: [String: Any] = [
            "renderer": renderer, "geometry": geometry, "reservedLeadingWidth": reservedLeadingWidth,
            "setupMS": setupMS, "frames": displayIntervals.count,
            "maxDisplayMS": displayIntervals.max() ?? 0, "maxCallbackMS": callbackIntervals.max() ?? 0,
            "p95DisplayMS": percentile(displayIntervals, fraction: 0.95),
            "elapsedSeconds": now - (start ?? now), "timedOut": timedOut,
            "reachedEnd": clip.bounds.maxY >= document.frame.height - 1,
            "documentHeight": document.frame.height, "documentWidth": document.frame.width,
            "viewportHeight": clip.bounds.height, "viewportWidth": clip.bounds.width,
            "windowWidth": window.contentView?.bounds.width ?? 0,
            "windowHeight": window.contentView?.bounds.height ?? 0,
            "backingScale": window.backingScaleFactor, "screenMaximumFPS": window.screen?.maximumFramesPerSecond ?? 0,
            "firstLineHeight": firstLineHeight,
            "fontSize": NSFont.systemFontSize - 1, "scrollPointsPerSecond": 7200, "load": load,
            "fixtureUTF16Count": fixture.utf16.count,
            "fixtureSHA256": SHA256.hash(data: Data(fixture.utf8)).map { String(format: "%02x", $0) }.joined(),
            "longFrames": longFrames,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("PROBE_RESULT=" + String(decoding: data, as: UTF8.self))
        } catch {
            print("PROBE_ERROR=\(error)")
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * fraction)]
    }
}

@main
struct Main {
    @MainActor static func main() {
        let renderer = ProcessInfo.processInfo.environment["SCROLL_PROBE_RENDERER"] ?? "sttextview"
        guard ["sttextview", "native"].contains(renderer) else {
            print("PROBE_ERROR=SCROLL_PROBE_RENDERER must be sttextview or native")
            exit(EXIT_FAILURE)
        }
        let geometry = ProcessInfo.processInfo.environment["SCROLL_PROBE_GEOMETRY"] ?? "source"
        guard ["source", "full"].contains(geometry) else {
            print("PROBE_ERROR=SCROLL_PROBE_GEOMETRY must be source or full")
            exit(EXIT_FAILURE)
        }
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = try ScrollProbe(renderer: renderer, geometry: geometry)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            print("PROBE_ERROR=\(error)")
            exit(EXIT_FAILURE)
        }
    }
}
