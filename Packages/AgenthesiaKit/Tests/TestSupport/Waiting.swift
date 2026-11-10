public import Testing

/// How long a test may wait for a condition: the running test's own time limit, or a minute for a test without one.
///
/// A loaded CI runner queues a main-actor test for most of a minute (#133), so a shorter deadline fails tests that would
/// have passed. A wait this long cannot end before the test's time limit does, which cancels the test and its wait.
public var waitLimit: Duration { Test.current?.timeLimit ?? .seconds(60) }

/// Polls `condition` on the caller's actor every 10 ms until it holds, and records `comment` at the caller if it does
/// not hold within `waitLimit` or the test is cancelled. Returns whether it held.
@discardableResult
public func eventually(
    isolation: isolated (any Actor)? = #isolation,
    _ comment: Comment = "Timed out waiting for the condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + waitLimit
    while !condition() {
        // Sleep rather than spin: a busy loop starves the other tests on the main actor. A cancelled sleep throws, so a
        // test past its time limit stops polling at once.
        guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(10))) != nil else {
            Issue.record(comment, sourceLocation: sourceLocation)
            return false
        }
    }
    return true
}

/// `eventually` that stops the test when the condition does not hold.
public func waitUntil(
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let held = await eventually("Timed out", sourceLocation: sourceLocation, condition)
    try #require(held, sourceLocation: sourceLocation)
}
