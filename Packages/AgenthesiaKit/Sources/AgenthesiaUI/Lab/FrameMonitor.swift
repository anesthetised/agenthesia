#if DEBUG
    import AppKit
    import os

    /// Measures frame times while a scenario runs, from the display link of the view's screen.
    final class FrameMonitor: NSObject {
        struct Report: Codable {
            var frames = 0
            var hitches = 0
            var estimatedMissed = 0
            var excessMilliseconds = 0.0
            var p50 = 0.0
            var p95 = 0.0
            var p99 = 0.0
            var max = 0.0
            /// The process's memory footprint at the end, in MB.
            var memory = 0.0
            /// The system's free memory at the end, in percent, as `memory_pressure` reports it.
            var freeMemory = 0
            /// The system's load average over the last minute; above the number of cores the CPU is short.
            var load = 0.0
        }

        static let signposter = OSSignposter(subsystem: "io.github.anesthetised.Agenthesia", category: "RenderingLab")

        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private var samples = FrameSamples()
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
                let budget = link.targetTimestamp - link.timestamp
                samples.record(interval: interval, budget: budget > 0 ? budget : link.duration)
            }
            last = link.timestamp
            if !onFrame() {
                completion(finish())
            }
        }

        private func finish() -> Report {
            let report = Report(
                frames: samples.intervals.count,
                hitches: samples.hitches,
                estimatedMissed: samples.estimatedMissed,
                excessMilliseconds: samples.excessMilliseconds,
                p50: samples.percentile(0.5),
                p95: samples.percentile(0.95),
                p99: samples.percentile(0.99),
                max: samples.intervals.max() ?? 0,
                memory: Self.memoryFootprint(),
                freeMemory: Self.freeMemory(),
                load: Self.load()
            )
            stop()
            return report
        }

        func stop() {
            link?.invalidate()
            link = nil
            last = nil
            samples = FrameSamples()
            if let signpost { Self.signposter.endInterval("Scenario", signpost) }
            signpost = nil
        }

        static func freeMemory() -> Int {
            var level: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : 0
        }

        static func load() -> Double {
            var load = 0.0
            return getloadavg(&load, 1) == 1 ? load : 0
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
