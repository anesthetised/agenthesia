#if DEBUG
    import AppKit
    import os

    /// Measures frame times while a scenario runs, from the display link of the view's screen.
    final class FrameMonitor: NSObject {
        struct Report {
            var frames = 0
            var dropped = 0
            var p50 = 0.0
            var p95 = 0.0
            var p99 = 0.0
            var max = 0.0
            /// The process's memory footprint at the end, in MB.
            var memory = 0.0
        }

        static let signposter = OSSignposter(subsystem: "io.github.anesthetised.Agenthesia", category: "RenderingLab")

        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private var intervals: [Double] = []
        private var dropped = 0
        private var onFrame: () -> Bool = { false }
        private var completion: (Report) -> Void = { _ in }
        private var signpost: OSSignpostIntervalState?

        /// Calls `onFrame` on every frame until it returns `false`, then reports the frame times.
        func run(in view: NSView, name: String, onFrame: @escaping () -> Bool, completion: @escaping (Report) -> Void) {
            stop()
            self.onFrame = onFrame
            self.completion = completion
            signpost = Self.signposter.beginInterval("Scenario", "\(name)")
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            if let last {
                let interval = link.timestamp - last
                intervals.append(interval * 1000)
                // A frame took longer than one refresh: the next one was missed.
                if interval > link.duration * 1.5 { dropped += 1 }
            }
            last = link.timestamp
            if !onFrame() {
                completion(finish())
            }
        }

        private func finish() -> Report {
            let sorted = intervals.sorted()
            func percentile(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]
            }
            let report = Report(
                frames: sorted.count,
                dropped: dropped,
                p50: percentile(0.5),
                p95: percentile(0.95),
                p99: percentile(0.99),
                max: sorted.last ?? 0,
                memory: Self.memoryFootprint()
            )
            stop()
            return report
        }

        func stop() {
            link?.invalidate()
            link = nil
            last = nil
            intervals = []
            dropped = 0
            if let signpost { Self.signposter.endInterval("Scenario", signpost) }
            signpost = nil
        }

        /// The memory footprint in MB, as Activity Monitor shows it.
        static func memoryFootprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
    }
#endif
