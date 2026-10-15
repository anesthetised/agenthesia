import ACPTesting
import Foundation
import JSONRPC

// A scriptable ACP agent over stdio, for manual runs and integration tests.
//
//     MockAgent                      reactive echo agent (see EchoAgent)
//     MockAgent --scenario <file>    plays a JSON scenario and exits non-zero on deviation
//     MockAgent --auth               echo agent that requires authentication
//     MockAgent --reopen             echo agent that resumes or loads sessions of earlier processes
//     MockAgent --no-resume          echo agent without session/resume
//     MockAgent --no-load            echo agent without session/load

let transport = FileHandleTransport(reading: .standardInput, writing: .standardOutput)
let arguments = CommandLine.arguments.dropFirst()

if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) {
    let url = URL(filePath: arguments[index + 1])
    let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    if let mismatch = await ScenarioAgent(scenario: scenario, transport: transport).run() {
        FileHandle.standardError.write(Data("MockAgent: \(mismatch)\n".utf8))
        exit(1)
    }
} else {
    var options = EchoAgent.Options()
    options.chunkDelay = .milliseconds(30)
    options.announcesCommands = true
    options.requiresAuthentication = arguments.contains("--auth")
    options.reopensUnknownSessions = arguments.contains("--reopen")
    options.resumeSession = !arguments.contains("--no-resume")
    options.loadSession = !arguments.contains("--no-load")
    await EchoAgent(options: options).serve(transport)
}
