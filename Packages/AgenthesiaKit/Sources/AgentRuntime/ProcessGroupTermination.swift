import Darwin
import Synchronization

/// Idempotent SIGTERM/SIGKILL cleanup of a child's process group, shared by agents and terminals.
/// Later calls can shorten, but never extend, the grace period.
final class ProcessGroupTermination: Sendable {
    private struct State {
        var deadline: ContinuousClock.Instant?
        var task: Task<Void, Never>?
    }

    private let group: Int32?
    private let leader: Int32
    private let leaderIsRunning: @Sendable () -> Bool
    private let state = Mutex(State())

    /// Without a verified private `group`, only the live `leader` is signaled.
    init(group: Int32?, leader: Int32, leaderIsRunning: @escaping @Sendable () -> Bool) {
        self.group = group
        self.leader = leader
        self.leaderIsRunning = leaderIsRunning
    }

    var hasStarted: Bool { state.withLock { $0.task != nil } }

    @discardableResult
    func start(gracePeriod: Duration) -> Task<Void, Never> {
        let requested = ContinuousClock.now.advanced(by: gracePeriod)
        return state.withLock { state in
            state.deadline = min(state.deadline ?? requested, requested)
            if let task = state.task { return task }
            let task = Task { await self.run() }
            state.task = task
            return task
        }
    }

    static func exists(_ group: Int32) -> Bool {
        guard group > 0, group != getpgrp() else { return false }
        return kill(-group, 0) == 0 || errno == EPERM
    }

    private var deadline: ContinuousClock.Instant { state.withLock { $0.deadline ?? .now } }

    private func run() async {
        if let group {
            if Self.exists(group) { kill(-group, SIGTERM) }
            while Self.exists(group) && ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            if Self.exists(group) { kill(-group, SIGKILL) }
        } else if leaderIsRunning() {
            kill(leader, SIGTERM)
            while leaderIsRunning() && ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            if leaderIsRunning() { kill(leader, SIGKILL) }
        }
    }
}
