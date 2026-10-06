#if DEBUG
    import Foundation

    /// Display-link intervals are a responsiveness proxy, not measured pixel presentation times.
    struct FrameSamples {
        private(set) var intervals: [Double] = []
        private(set) var hitches = 0
        private(set) var estimatedMissed = 0
        private(set) var excessMilliseconds = 0.0

        mutating func record(interval: Double, budget: Double) {
            guard interval.isFinite, budget.isFinite, interval > 0, budget > 0 else { return }
            intervals.append(interval * 1000)
            if interval > budget * 1.5 { hitches += 1 }
            estimatedMissed += max(0, Int((interval / budget).rounded()) - 1)
            excessMilliseconds += max(0, interval - budget) * 1000
        }

        func percentile(_ fraction: Double) -> Double {
            let sorted = intervals.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }
    }

    /// Replays a virtual producer whose arrival times do not depend on UI callback frequency.
    /// Due chunks are coalesced once per callback, matching the planned frame-coalesced UI pipeline.
    struct StreamSchedule {
        let chunks: [String]
        let interval: Double
        private(set) var consumed = 0
        private(set) var peakBacklog = 0
        private(set) var latencies: [Double] = []

        init(chunks: [String], interval: Double) {
            precondition(interval.isFinite && interval > 0)
            self.chunks = chunks
            self.interval = interval
        }

        var isComplete: Bool { consumed == chunks.count }

        /// The half-open range of chunks already due at `elapsed` seconds; first arrival is at zero.
        func due(at elapsed: Double) -> Range<Int> {
            guard elapsed.isFinite, elapsed >= 0 else { return consumed..<consumed }
            let count = min(Double(chunks.count), floor(elapsed / interval) + 1)
            return consumed..<max(consumed, Int(count))
        }

        mutating func recordApplied(_ batch: Range<Int>, at elapsed: Double) {
            precondition(batch.lowerBound == consumed && batch.upperBound <= chunks.count)
            peakBacklog = max(peakBacklog, due(at: elapsed).count)
            for index in batch { latencies.append(max(0, elapsed - Double(index) * interval) * 1000) }
            consumed = batch.upperBound
        }

        var p95Latency: Double {
            let sorted = latencies.sorted()
            return sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * 0.95).rounded())]
        }
    }
#endif
