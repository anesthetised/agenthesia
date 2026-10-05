import ACPTesting
import Foundation
import JSONRPC

// A scriptable ACP agent over stdio, for manual runs and integration tests.
//
//     MockAgent                      reactive echo agent (see EchoAgent)
//     MockAgent --scenario <file>    plays a JSON scenario and exits non-zero on deviation
//     MockAgent --auth               echo agent that requires authentication

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
    options.requiresAuthentication = arguments.contains("--auth")
    await EchoAgent(options: options).serve(transport)
}
