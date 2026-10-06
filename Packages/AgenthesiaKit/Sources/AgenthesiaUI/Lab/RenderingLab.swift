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
                    TableColumn("Open, ms") { Text($0.open.map { format($0) } ?? "–") }
                    TableColumn("Frames") { Text("\($0.report.frames)") }
                    TableColumn("Dropped") { Text("\($0.report.dropped)") }
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

    struct LabResult: Identifiable {
        let id = UUID()
        var scenario: String
        /// How long the content took to appear, in ms; `nil` if the scenario does not open anything.
        var open: Double?
        var report: FrameMonitor.Report
    }

    /// The transcript prototypes.
    enum Prototype: String, CaseIterable {
        case table = "A"
        case tableTextKit = "A2"
        case document = "B"
        case swiftUI = "C"

        var title: String {
            switch self {
            case .table: "A: NSTableView"
            case .tableTextKit: "A′: NSTableView + TextKit 2"
            case .document: "B: TextKit 2"
            case .swiftUI: "C: SwiftUI"
            }
        }

        func make() -> any TranscriptPrototype {
            switch self {
            case .table: TableTranscript()
            case .tableTextKit: TableTranscript(textKit: true)
            case .document: DocumentTranscript()
            case .swiftUI: SwiftUITranscript()
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
                case "S2": await runScroll()
                case "S5": await runAppearance()
                default:
                    let flags = argument.split(separator: "+")
                    lineNumbers = flags.contains("lines")
                    highlighting = flags.contains("colors")
                    await runSourceView()
                }
            }
            print(markdown)
            NSApp.terminate(nil)
        }

        /// S1: stream a ~4000-token answer into a 200-item transcript, following its end.
        func runStream() async {
            var generator = TranscriptGenerator(seed: 1)
            let transcript = LabTranscript(items: generator.items(200))
            var chunks = generator.chunks(of: generator.answer(tokens: 4000))[...]
            let view = await present(prototype.make())
            view.show(transcript)
            view.view.layoutSubtreeIfNeeded()
            if let scrollView = view.scrollView { scrollToEnd(scrollView) }
            transcript.startStreaming()
            view.didAppend()
            // A chunk a frame: about 1500 characters a second, faster than agents stream.
            await measure("S1 Stream, \(prototype.title)", in: view.view) {
                guard let chunk = chunks.popFirst() else { return false }
                view.didStream(transcript.stream(chunk))
                return true
            }
        }

        /// S2: open a 10 000-item transcript at its end, then scroll up 120 points a frame (a fast flick) for 3000
        /// frames.
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
            var frames = 0
            await measure("S2 10k items, \(prototype.title)", open: open, in: view.view) {
                frames += 1
                let y = max(clip.bounds.origin.y - 120, 0)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                return y > 0 && frames < 3000
            }
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
                return frame < 150
            }
            window?.appearance = nil
        }

        /// S4: open a 10 000-line Swift file, then scroll it from top to bottom.
        func runSourceView() async {
            let text = TranscriptGenerator.swiftFile(lines: 10_000)
            let sourceView = await present(SourceView())
            let start = ContinuousClock.now
            sourceView.showsLineNumbers = lineNumbers
            sourceView.setText(text, language: highlighting ? .swift : nil)
            sourceView.layoutSubtreeIfNeeded()
            let open = milliseconds(since: start)

            let flags = [lineNumbers ? "lines" : nil, highlighting ? "colors" : nil].compactMap(\.self)
            let name = "S4 SourceView" + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
            let scrollView = sourceView.scrollView
            let clip = scrollView.contentView
            clip.scroll(to: .zero)
            await measure(name, open: open, in: sourceView) {
                // TextKit 2 estimates the height as it lays out, so the end is recomputed on every frame.
                let end = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
                let y = min(clip.bounds.origin.y + 60, end)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                return y < end
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
            results.append(LabResult(scenario: name, open: open, report: report))
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
                "| Scenario | Open, ms | Frames | Dropped | p50, ms | p95, ms | p99, ms | Max, ms | Memory, MB "
                    + "| Free RAM, % | Load, \(ProcessInfo.processInfo.activeProcessorCount) cores |",
                "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|",
            ]
            for result in results {
                let report = result.report
                let values = [
                    result.scenario, result.open.map { format($0) } ?? "–", "\(report.frames)", "\(report.dropped)",
                    format(report.p50), format(report.p95), format(report.p99), format(report.max),
                    format(report.memory), "\(report.freeMemory)", format(report.load),
                ]
                lines.append("| " + values.joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n")
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
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
