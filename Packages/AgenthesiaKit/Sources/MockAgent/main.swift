import ACPTesting
import Foundation
import JSONRPC

// A scriptable ACP agent over stdio, for manual runs and integration tests.
//
//     MockAgent                      reactive echo agent (see EchoAgent)
//     MockAgent --scenario <file>    plays a JSON scenario and exits non-zero on deviation
//     MockAgent --auth               echo agent that requires authentication, unless the sign-in file exists
//     MockAgent --auth-file <file>   the sign-in file (default: agenthesia-mock-agent-signed-in in the temporary
//                                    directory)
//     MockAgent --login              terminal sign-in: asks on the terminal, then `yes` creates the sign-in file
//                                    and exits 0, `skip` exits 0 without it, anything else exits 1
//     MockAgent --reopen             echo agent that resumes or loads sessions of earlier processes
//     MockAgent --no-resume          echo agent without session/resume
//     MockAgent --no-load            echo agent without session/load
//     MockAgent --no-config          echo agent without modes or config options
//     MockAgent --effort             echo agent that also offers an effort (thought_level) config option
//     MockAgent --fast               echo agent that also offers a boolean `Fast mode` config option
//     MockAgent --reject-config      echo agent that refuses every mode and config change
//
// The stdio MCP servers a client passes in session/new, session/load or session/resume are started, and the prompt verb
// `mcp <tool> <json>` calls a tool on them (see EchoAgent).
//
//     MockAgent --demo <file>        echo agent that plays the canned turn in <file> on every prompt (see
//                                    EchoAgent.Options.demo); scripts/readme-screenshot.sh uses it

// Created only in the agent modes: it starts reading standard input, which `--login` needs for itself.
func transport() -> FileHandleTransport { FileHandleTransport(reading: .standardInput, writing: .standardOutput) }
let arguments = CommandLine.arguments.dropFirst()

let signInFile =
    arguments.firstIndex(of: "--auth-file").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    .map { URL(filePath: $0) }
    ?? FileManager.default.temporaryDirectory.appending(path: "agenthesia-mock-agent-signed-in")

if arguments.contains("--login") {
    print("Mock sign-in. Type yes to sign in: ", terminator: "")
    fflush(stdout)
    switch readLine() {
    case "yes":
        FileManager.default.createFile(atPath: signInFile.path(percentEncoded: false), contents: Data())
        print("Signed in.")
    case "skip":
        print("Skipped.")
    default:
        print("Sign-in failed.")
        exit(1)
    }
} else if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) {
    let url = URL(filePath: arguments[index + 1])
    let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    if let mismatch = await ScenarioAgent(scenario: scenario, transport: transport()).run() {
        FileHandle.standardError.write(Data("MockAgent: \(mismatch)\n".utf8))
        exit(1)
    }
} else {
    var options = EchoAgent.Options()
    options.chunkDelay = .milliseconds(30)
    options.announcesCommands = true
    options.requiresAuthentication =
        arguments.contains("--auth") && !FileManager.default.fileExists(atPath: signInFile.path(percentEncoded: false))
    options.reopensUnknownSessions = arguments.contains("--reopen")
    options.resumeSession = !arguments.contains("--no-resume")
    options.loadSession = !arguments.contains("--no-load")
    options.modes = !arguments.contains("--no-config")
    options.configOptions = !arguments.contains("--no-config")
    options.effort = arguments.contains("--effort") && !arguments.contains("--no-config")
    options.fastMode = arguments.contains("--fast") && !arguments.contains("--no-config")
    options.rejectsConfigChanges = arguments.contains("--reject-config")
    if let index = arguments.firstIndex(of: "--demo"), arguments.indices.contains(index + 1) {
        options.demo = try String(contentsOfFile: arguments[index + 1], encoding: .utf8)
    }
    await EchoAgent(options: options).serve(transport())
}
