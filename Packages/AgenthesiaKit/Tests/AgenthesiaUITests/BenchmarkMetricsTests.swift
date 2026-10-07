#if DEBUG
    import Testing

    @testable import AgenthesiaUI

    @MainActor
    @Suite struct BenchmarkMetricsTests {
        @Test func countsHitchesSeparatelyFromMissedIntervals() {
            var samples = FrameSamples()
            let budget = 1.0 / 120
            samples.record(interval: budget, budget: budget)
            samples.record(interval: budget * 3, budget: budget)
            samples.record(interval: budget * 30, budget: budget)
            #expect(samples.hitches == 2)
            #expect(samples.estimatedMissed == 31)
            #expect(abs(samples.excessMilliseconds - 31 * budget * 1000) < 0.001)
            #expect(samples.percentile(0.5) == budget * 3 * 1000)
        }

        @Test func handlesEmptySamplesInvalidBudgetsAndRefreshChanges() {
            var samples = FrameSamples()
            #expect(samples.percentile(0.95) == 0)
            samples.record(interval: 1, budget: 0)
            samples.record(interval: .infinity, budget: 1)
            samples.record(interval: -1, budget: 1)
            samples.record(interval: 1, budget: .nan)
            #expect(samples.intervals.isEmpty)
            samples.record(interval: 1.0 / 60, budget: 1.0 / 60)
            samples.record(interval: 1.0 / 120, budget: 1.0 / 120)
            #expect(samples.estimatedMissed == 0)
            #expect(samples.hitches == 0)
        }

        @Test func aUIStallDoesNotSlowTheProducerOrLoseChunks() {
            var stream = StreamSchedule(chunks: ["a", "b", "c", "d", "e"], interval: 0.01)
            #expect(stream.due(at: -1).isEmpty)
            #expect(stream.due(at: .infinity).isEmpty)
            #expect(stream.due(at: 0) == 0..<1)
            stream.recordApplied(0..<1, at: 0.005)
            #expect(stream.due(at: 0.005).isEmpty)
            // A 35 ms stall makes three more chunks due, rather than just one per callback.
            let batch = stream.due(at: 0.035)
            #expect(batch == 1..<4)
            #expect(stream.chunks[batch].joined() == "bcd")
            stream.recordApplied(batch, at: 0.045)
            #expect(stream.peakBacklog == 4)  // Includes the chunk arriving during the UI update.
            #expect(stream.due(at: 0.045) == 4..<5)
            stream.recordApplied(4..<5, at: 0.05)
            #expect(stream.isComplete)
            #expect(stream.due(at: 100).isEmpty)
            #expect(abs(stream.p95Latency - 35) < 0.001)
            #expect(stream.latencies.count == 5)
        }

        @Test func emptyStreamIsAlreadyComplete() {
            let stream = StreamSchedule(chunks: [], interval: 0.01)
            #expect(stream.isComplete)
            #expect(stream.due(at: 1).isEmpty)
            #expect(stream.p95Latency == 0)
        }
    }
#endif
