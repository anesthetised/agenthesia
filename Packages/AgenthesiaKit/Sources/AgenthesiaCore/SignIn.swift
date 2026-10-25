public import ACP
import AgentRuntime
public import Foundation
import Observation

extension LiveSession {
    /// The agent asked for sign-in before the session could start or continue (ADR-0033).
    public struct SignIn: Equatable, Sendable {
        /// The agent's methods, in its order.
        public let methods: [ACP.AuthMethod]
        /// The method being tried.
        public var pending: ACP.AuthMethodID?
        /// Why the last attempt did not sign in, if it says.
        public var message: String?
    }
}

/// A terminal sign-in method's command, shown while it runs and after it fails (ADR-0033).
@MainActor @Observable
public final class SignInTerminal: Identifiable {
    /// The method's name.
    public let title: String
    /// Set when the command has exited.
    public private(set) var exitMessage: String?
    @ObservationIgnored private let process: TerminalProcess

    init(title: String, process: TerminalProcess) {
        self.title = title
        self.process = process
    }

    /// Everything the command wrote so far, then each later chunk; finishes when its output ends.
    public func output() -> AsyncStream<Data> { process.outputUpdates() }

    public func write(_ data: Data) { process.write(data) }

    public func resize(columns: UInt16, rows: UInt16) { process.resize(columns: columns, rows: rows) }

    func waitForExit() async -> ExitStatus {
        let status = await process.waitForExit()
        exitMessage =
            switch status {
            case .exited(let code): "Sign-in exited with status \(code)."
            case .signaled(let signal): "Sign-in was stopped by signal \(signal)."
            }
        return status
    }

    func terminate() async { _ = await process.terminate() }
}
