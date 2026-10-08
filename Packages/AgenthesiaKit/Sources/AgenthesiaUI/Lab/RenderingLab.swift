#if DEBUG
    import AppKit
    import Rendering
    public import SwiftUI

    /// A debug window that runs rendering scenarios and measures them.
    public struct RenderingLabView: View {
        public static let windowID = "rendering-lab"

        /// Whether the app was launched to run scenarios unattended (see ``RenderingLab/autorun()``).
        public static var isAutorun: Bool { RenderingLab.autorunScenarios != nil }

        @State private var lab = RenderingLab()

        public init() {}

        public var body: some View {
            VStack(alignment: .leading) {
                HStack {
                    Picker("Transcript", selection: $lab.prototype) {
                        ForEach(Prototype.allCases, id: \.self) { Text($0.title) }
                    }
                    .fixedSize()
                    Button("S1: Stream") { Task { await lab.runStream() } }
                    Button("S6: Long code") { Task { await lab.runStream(longCode: true) } }
                    Button("S2: 10k items") { Task { await lab.runScroll() } }
                    Button("S3: Selection") { Task { await lab.showForSelection() } }
                    Button("S5: Appearance") { Task { await lab.runAppearance() } }
                    Spacer()
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lab.markdown, forType: .string)
                    }
                    .disabled(lab.results.isEmpty)
                }
                .disabled(lab.isRunning)
                HStack {
                    Button("S4: SourceView, 10k lines") { Task { await lab.runSourceView() } }
                    Toggle("Line numbers", isOn: $lab.lineNumbers)
                    Toggle("Highlighting", isOn: $lab.highlighting)
                }
                .disabled(lab.isRunning)
                ViewHost(view: lab.content)
                    .id(ObjectIdentifier(lab.content))
                    .frame(minHeight: 300)
                Table(lab.results) {
                    TableColumn("Scenario", value: \.scenario)
                    TableColumn("Setup, ms") { Text($0.open.map { format($0) } ?? "–") }
                    TableColumn("Callbacks") { Text("\($0.report.frames)") }
                    TableColumn("Hitches / missed≈") { Text("\($0.report.hitches) / \($0.report.estimatedMissed)") }
                    TableColumn("p50") { Text(format($0.report.p50)) }
                    TableColumn("p95") { Text(format($0.report.p95)) }
                    TableColumn("p99") { Text(format($0.report.p99)) }
                    TableColumn("Max") { Text(format($0.report.max)) }
                    TableColumn("Memory, MB") { Text(format($0.report.memory)) }
                    // A table takes at most ten columns.
                    TableColumn("Free RAM, load") { Text("\($0.report.freeMemory)%, \(format($0.report.load))") }
                }
                .frame(height: 160)
            }
            .padding()
            .frame(minWidth: 800, minHeight: 600)
            // On the whole window: a task on the view under test would start again with every new view.
            .task { await lab.autorun() }
        }
    }

    /// The Debug menu with the Rendering Lab.
    public struct RenderingLabCommands: Commands {
        public init() {}

        public var body: some Commands {
            CommandMenu("Debug") {
                OpenRenderingLabButton()
            }
        }
    }

    private struct OpenRenderingLabButton: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Rendering Lab") { openWindow(id: RenderingLabView.windowID) }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }

    // MARK: - Scenarios

    struct LabResult: Identifiable, Encodable {
        let id = UUID()
        var scenario: String
        /// Synchronous content setup and layout, not time to first presented pixels.
        var open: Double?
        var report: FrameMonitor.Report
        var measurements: [String: Double] = [:]
    }

    /// The transcript prototypes.
    enum Prototype: String, CaseIterable {
        case table = "A"
        case tableTextKit = "A2"
        case document = "B"
        case swiftUI = "C"
        case app = "App"

        var title: String {
            switch self {
            case .table: "A: NSTableView"
            case .tableTextKit: "A′: NSTableView + TextKit 2"
            case .document: "B: TextKit 2"
            case .swiftUI: "C: SwiftUI"
            case .app: "App: production transcript"
            }
        }

        func make() -> any TranscriptPrototype {
            switch self {
            case .table: TableTranscript()
            case .tableTextKit: TableTranscript(textKit: true)
            case .document: DocumentTranscript()
            case .swiftUI: SwiftUITranscript()
            case .app: AppTranscriptPrototype()
            }
        }
    }

    @Observable
    final class RenderingLab {
        private(set) var results: [LabResult] = []
        private(set) var isRunning = false
        var prototype = Prototype.table
        var lineNumbers = true
        var highlighting = true
        /// The view under test. Every run gets a new one, as an opened file or session does: reusing one makes
        /// TextKit relayout the old text.
        private(set) var content = NSView()
        private let monitor = FrameMonitor()
        private var didAutorun = false

        /// Runs from `AGENTHESIA_LAB_RUNS`, such as `S1:A,S2:B,S4:lines+colors`: a scenario and its prototype, or
        /// for S4 the SourceView flags.
        static let autorunScenarios = ProcessInfo.processInfo.environment["AGENTHESIA_LAB_RUNS"]?
            .split(separator: ",").map(String.init)

        /// Runs the scenarios from the environment, prints the results as Markdown and quits.
        func autorun() async {
            guard let scenarios = Self.autorunScenarios, !didAutorun else { return }
            didAutorun = true
            // Launched from a terminal, the app stays behind it, and a window in the back gets a throttled display
            // link: the first scenario measured that until the app was brought forward and given time to settle.
            NSApp.activate()
            try? await Task.sleep(for: .seconds(1))
            for scenario in scenarios {
                let parts = scenario.split(separator: ":").map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                prototype = Prototype(rawValue: argument) ?? .table
                switch parts[0] {
                case "S1": await runStream()
                case "S6": await runStream(longCode: true)
                case "S2": await runScroll()
                case "S5": await runAppearance()
                default:
                    let flags = argument.split(separator: "+")
                    lineNumbers = flags.contains("lines")
                    highlighting = flags.contains("colors")
                    await runSourceView(cold: flags.contains("cold"), appKitHost: flags.contains("appkit"))
                }
            }
            print(markdown)
            for result in results {
                if let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) {
                    print("BENCHMARK_RESULT=" + json)
                }
            }
            NSApp.terminate(nil)
        }

        /// S1: stream a ~4000-token answer into a 200-item transcript, following its end.
        func runStream(longCode: Bool = false) async {
            var generator = TranscriptGenerator(seed: 1)
            let transcript = LabTranscript(items: generator.items(200))
            let answer =
                longCode
                ? "```swift\n" + TranscriptGenerator.swiftFile(lines: 400)
                : generator.answer(tokens: 4000)
            let chunks = generator.chunks(of: answer)
            var schedule = StreamSchedule(chunks: chunks, interval: 0.01)
            let view = await present(prototype.make())
            view.show(transcript)
            view.view.layoutSubtreeIfNeeded()
            if let scrollView = view.scrollView { scrollToEnd(scrollView) }
            transcript.startStreaming()
            view.didAppend()
            // The virtual producer emits 100 chunks/s even when the UI stalls. No timer can silently slow it.
            let start = ContinuousClock.now
            let name = longCode ? "S6 Long unclosed code" : "S1 Stream"
            await measure("\(name), \(prototype.title), warm", in: view.view) {
                guard !schedule.isComplete else { return false }  // Observe a callback after the final update.
                let batch = schedule.due(at: milliseconds(since: start) / 1000)
                guard !batch.isEmpty else { return true }
                if let app = view as? AppTranscriptPrototype {
                    app.append(chunks[batch].joined())
                } else {
                    view.didStream(transcript.stream(chunks[batch].joined()))
                }
                schedule.recordApplied(batch, at: milliseconds(since: start) / 1000)
                return true
            }
            results[results.count - 1].measurements.merge([
                "chunkIntervalMS": schedule.interval * 1000,
                "chunks": Double(chunks.count), "characters": Double(answer.count),
                "elapsedMS": milliseconds(since: start), "peakBacklogChunks": Double(schedule.peakBacklog),
                "applyLatencyP95MS": schedule.p95Latency, "applyLatencyMaxMS": schedule.latencies.max() ?? 0,
            ]) { _, new in new }
        }

        /// S2: open 10 000 items, then scroll at 14 400 points/s for at most 25 seconds.
        func runScroll() async {
            var generator = TranscriptGenerator(seed: 2)
            let transcript = LabTranscript(items: generator.items(10_000))
            let view = await present(prototype.make())
            guard let scrollView = view.scrollView else { return }
            let start = ContinuousClock.now
            view.show(transcript)
            view.view.layoutSubtreeIfNeeded()
            scrollToEnd(scrollView)
            let open = milliseconds(since: start)
            let clip = scrollView.contentView
            let scrollStart = ContinuousClock.now
            var previous = scrollStart
            var done = false
            await measure("S2 10k items, \(prototype.title)", open: open, in: view.view) {
                if done { return false }
                let step = milliseconds(since: previous) / 1000 * 14_400
                previous = .now
                let y = max(clip.bounds.origin.y - step, 0)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                done = (y <= 0 && view.isComplete) || milliseconds(since: scrollStart) >= 25_000
                return true
            }
            results[results.count - 1].measurements.merge([
                "allItemsAvailable": view.isComplete ? 1 : 0,
                "reachedStart": clip.bounds.origin.y <= 0 ? 1 : 0,
                "elapsedMS": milliseconds(since: scrollStart), "scrollPointsPerSecond": 14_400,
            ]) { _, new in new }
        }

        /// S3: show a 200-item transcript to select and copy text by hand.
        func showForSelection() async {
            var generator = TranscriptGenerator(seed: 1)
            let view = await present(prototype.make())
            view.show(LabTranscript(items: generator.items(200)))
            view.view.layoutSubtreeIfNeeded()
            if let scrollView = view.scrollView { scrollToEnd(scrollView) }
            isRunning = false
        }

        /// S5: switch between light and dark appearance ten times on a 200-item transcript.
        func runAppearance() async {
            var generator = TranscriptGenerator(seed: 1)
            let transcript = LabTranscript(items: generator.items(200))
            let view = await present(prototype.make())
            view.show(transcript)
            view.view.layoutSubtreeIfNeeded()
            if let scrollView = view.scrollView { scrollToEnd(scrollView) }
            let window = view.view.window
            var frame = 0
            await measure("S5 Appearance, \(prototype.title)", in: view.view) {
                frame += 1
                if frame % 15 == 0 {
                    window?.appearance = NSAppearance(named: frame / 15 % 2 == 1 ? .darkAqua : .aqua)
                }
                return frame <= 150  // Include the interval after the last appearance change.
            }
            window?.appearance = nil
        }

        /// S4: open a 10 000-line Swift file, observing setup and asynchronous highlight completion separately.
        /// A cold run must be the only scenario in a fresh process (the benchmark runner enforces this).
        func runSourceView(cold: Bool = false, appKitHost: Bool = false) async {
            let text = TranscriptGenerator.swiftFile(lines: 10_000)
            if !cold, highlighting { _ = Highlighter().highlight("x", language: .swift) }
            let sourceView: SourceView
            var controlWindow: NSWindow?
            if appKitHost {
                // Diagnostic control: keep SourceView intact, removing its SwiftUI hosting ancestors.
                isRunning = true
                sourceView = SourceView()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 868, height: 340),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = sourceView
                window.title = "SourceView AppKit hosting control"
                window.center()
                window.makeKeyAndOrderFront(nil)
                controlWindow = window
            } else {
                sourceView = await present(SourceView())
            }
            defer { controlWindow?.close() }
            let flags = [lineNumbers ? "lines" : nil, highlighting ? "colors" : nil, appKitHost ? "appkit" : nil]
                .compactMap(\.self)
            let options = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            let name = "S4 SourceView, \(cold ? "cold" : "warm")\(options)"
            let scrollView = sourceView.scrollView
            let clip = scrollView.contentView
            var start: ContinuousClock.Instant?
            var previous = ContinuousClock.now
            var setup = 0.0
            var firstCallback: Double?
            var done = false
            await measure(name, in: sourceView) { [lineNumbers, highlighting] in
                if done { return false }  // Include the interval after the final UI update.
                guard let start else {
                    let setupStart = ContinuousClock.now
                    start = setupStart
                    sourceView.showsLineNumbers = lineNumbers
                    sourceView.setText(text, language: highlighting ? .swift : nil)
                    sourceView.layoutSubtreeIfNeeded()
                    setup = milliseconds(since: setupStart)
                    previous = .now
                    return true
                }
                if firstCallback == nil { firstCallback = milliseconds(since: start) }
                let step = milliseconds(since: previous) / 1000 * 7200
                previous = .now
                let end = max(0, (clip.documentView?.frame.height ?? 0) - clip.bounds.height)
                let y = min(clip.bounds.origin.y + step, end)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                done = y >= end && (!highlighting || sourceView.highlightCompletedAt != nil)
                return true
            }
            let index = results.count - 1
            results[index].open = setup
            // The outer SourceView includes the gutter's reserved width, even when it is hidden.
            results[index].measurements["textViewportWidth"] = clip.bounds.width
            results[index].measurements["textViewportHeight"] = clip.bounds.height
            results[index].measurements["documentWidth"] = sourceView.textView.frame.width
            results[index].measurements["documentHeight"] = sourceView.textView.frame.height
            results[index].measurements["firstCallbackAfterSetupMS"] = firstCallback
            if let start, let completed = sourceView.highlightCompletedAt {
                results[index].measurements["highlightCompleteMS"] = milliseconds(since: start, until: completed)
            }
        }

        /// Shows `view` in the lab and waits until SwiftUI puts it in the window, so that opening it is measured
        /// with its layout.
        private func present(_ view: SourceView) async -> SourceView {
            isRunning = true
            content = view
            while view.window == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return view
        }

        private func present(_ prototype: any TranscriptPrototype) async -> any TranscriptPrototype {
            isRunning = true
            // Grammars load once per app, ~230 ms the first time each: not part of opening a transcript.
            for language in CodeLanguage.allCases { _ = Highlighter().highlight("x", language: language) }
            content = prototype.view
            while prototype.view.window == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return prototype
        }

        /// Calls `onFrame` on every frame until it returns `false` and adds the frame times to the results.
        private func measure(
            _ name: String,
            open: Double? = nil,
            in view: NSView,
            onFrame: @escaping () -> Bool
        ) async {
            let report = await withCheckedContinuation { continuation in
                monitor.run(in: view, name: name, onFrame: onFrame) { continuation.resume(returning: $0) }
            }
            results.append(
                LabResult(
                    scenario: name,
                    open: open,
                    report: report,
                    measurements: [
                        "viewportWidth": view.bounds.width, "viewportHeight": view.bounds.height,
                        "backingScale": view.window?.backingScaleFactor ?? 1,
                        "screenMaximumFPS": Double(view.window?.screen?.maximumFramesPerSecond ?? 0),
                    ]
                )
            )
            if let directory = Self.snapshotDirectory { snapshot(view, to: directory, name: name) }
            isRunning = false
        }

        /// Where unattended runs save a picture of the view after each scenario: `AGENTHESIA_LAB_SNAPSHOTS`.
        static let snapshotDirectory = ProcessInfo.processInfo.environment["AGENTHESIA_LAB_SNAPSHOTS"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }

        private func snapshot(_ view: NSView, to directory: URL, name: String) {
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            let file = directory.appending(path: name.replacing(/[^A-Za-z0-9]+/, with: "-") + ".png")
            try? image.representation(using: .png, properties: [:])?.write(to: file)
        }

        /// The results as a Markdown table, for the ADR.
        var markdown: String {
            var lines = [
                "| Scenario | Setup, ms | Callbacks | Hitches | Missed≈ | Excess, ms | p50, ms | p95, ms | p99, ms | Max, ms | Memory, MB "
                    + "| Free RAM, % | Load, \(ProcessInfo.processInfo.activeProcessorCount) cores |",
                "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|",
            ]
            for result in results {
                let report = result.report
                let values = [
                    result.scenario, result.open.map { format($0) } ?? "–", "\(report.frames)", "\(report.hitches)",
                    "\(report.estimatedMissed)", format(report.excessMilliseconds),
                    format(report.p50), format(report.p95), format(report.p99), format(report.max),
                    format(report.memory), "\(report.freeMemory)", format(report.load),
                ]
                lines.append("| " + values.joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n")
        }
    }

    private func milliseconds(
        since start: ContinuousClock.Instant,
        until end: ContinuousClock.Instant = .now
    ) -> Double {
        let elapsed = end - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Shows an AppKit view owned by the caller.
    struct ViewHost: NSViewRepresentable {
        let view: NSView

        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif
