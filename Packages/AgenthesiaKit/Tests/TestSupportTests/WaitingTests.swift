import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1))) struct WaitingTests {
    @Test func theLimitIsTheTestsOwnTimeLimit() {
        #expect(waitLimit == .seconds(60))
    }

    @Test func returnsOnceTheConditionHolds() async {
        var checks = 0
        let held = await eventually {
            checks += 1
            return checks == 3
        }
        #expect(held && checks == 3)
    }

    /// A test past its time limit is cancelled; its wait has to end then, not poll on until its own deadline.
    @Test func cancellationEndsTheWaitWithAnIssue() async {
        let start = ContinuousClock.now
        await withKnownIssue {
            let waiting = Task { await eventually { false } }
            waiting.cancel()
            #expect(await !waiting.value)
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func waitUntilStopsTheTestWhenTheConditionDoesNotHold() async {
        await withKnownIssue {
            let waiting = Task { try await waitUntil { false } }
            waiting.cancel()
            try await waiting.value
        }
    }
}
