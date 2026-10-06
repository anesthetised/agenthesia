#if DEBUG
    import AppKit
    import Rendering
    public import SwiftUI

    /// A debug window that runs rendering scenarios and measures them.
    public struct RenderingLabView: View {
        public static let windowID = "rendering-lab"

        @State private var lab = RenderingLab()

        public init() {}

        public var body: some View {
            VStack(alignment: .leading) {
                HStack {
                    Button("S4: SourceView, 10k lines") { lab.runSourceView() }
                    Toggle("Line numbers", isOn: $lab.lineNumbers)
                    Toggle("Highlighting", isOn: $lab.highlighting)
                        .disabled(lab.isRunning)
                    Spacer()
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lab.markdown, forType: .string)
                    }
                    .disabled(lab.results.isEmpty)
                }
                ViewHost(view: lab.sourceView)
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
                }
                .frame(height: 160)
            }
            .padding()
            .frame(minWidth: 800, minHeight: 600)
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

    @Observable
    final class RenderingLab {
        private(set) var results: [LabResult] = []
        private(set) var isRunning = false
        var lineNumbers = true
        var highlighting = true
        let sourceView = SourceView()
        private let monitor = FrameMonitor()

        /// S4: open a 10 000-line Swift file, then scroll it from top to bottom.
        func runSourceView() {
            isRunning = true
            let text = TranscriptGenerator.swiftFile(lines: 10_000)
            let start = ContinuousClock.now
            sourceView.textView.showsLineNumbers = lineNumbers
            sourceView.setText(text, language: highlighting ? .swift : nil)
            sourceView.layoutSubtreeIfNeeded()
            let open = milliseconds(since: start)

            let flags = [lineNumbers ? "lines" : nil, highlighting ? "colors" : nil].compactMap(\.self)
            let name = "S4 SourceView" + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
            let scrollView = sourceView.scrollView
            let clip = scrollView.contentView
            clip.scroll(to: .zero)
            monitor.run(in: sourceView, name: name) {
                // TextKit 2 estimates the height as it lays out, so the end is recomputed on every frame.
                let end = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
                let y = min(clip.bounds.origin.y + 60, end)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                return y < end
            } completion: { report in
                self.results.append(LabResult(scenario: name, open: open, report: report))
                self.isRunning = false
            }
        }

        /// The results as a Markdown table, for the ADR.
        var markdown: String {
            var lines = [
                "| Scenario | Open, ms | Frames | Dropped | p50, ms | p95, ms | p99, ms | Max, ms | Memory, MB |",
                "|---|--:|--:|--:|--:|--:|--:|--:|--:|",
            ]
            for result in results {
                let report = result.report
                let values = [
                    result.scenario, result.open.map { format($0) } ?? "–", "\(report.frames)", "\(report.dropped)",
                    format(report.p50), format(report.p95), format(report.p99), format(report.max),
                    format(report.memory),
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
