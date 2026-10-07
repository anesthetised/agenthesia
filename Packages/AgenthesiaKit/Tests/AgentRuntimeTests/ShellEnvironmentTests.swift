import AgentRuntime
import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ShellEnvironmentTests {
    @Test func parsesMarkedNulEnvironmentAndCachesConcurrentRequests() async throws {
        let counter = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-shell-count-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: counter) }
        let fixture = try shell(
            """
            printf x >> "$AGENTHESIA_TEST_COUNTER"
            printf 'startup noise\\n'
            export AGENTHESIA_TEST_VALUE='first=second'
            export AGENTHESIA_TEST_EMPTY=''
            export AGENTHESIA_TEST_LINES='one
            two'
            while [ "$#" -gt 0 ]; do
                if [ "$1" = '-c' ]; then shift; eval "$1"; break; fi
                shift
            done
            printf 'trailer noise\\n'
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(
            shell: fixture.path(),
            environment: ["PATH": "/usr/bin:/bin", "AGENTHESIA_TEST_COUNTER": counter.path()]
        )
        let results = await withTaskGroup(of: ShellEnvironment.Resolution.self) { group in
            for _ in 0..<8 { group.addTask { await resolver.resolve() } }
            var results: [ShellEnvironment.Resolution] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 8)
        for result in results {
            #expect(result.diagnostic == nil)
            #expect(result.environment["AGENTHESIA_TEST_VALUE"] == "first=second")
            #expect(result.environment["AGENTHESIA_TEST_EMPTY"] == "")
            #expect(result.environment["AGENTHESIA_TEST_LINES"] == "one\ntwo")
            #expect(result.environment["HOME"] != nil)
            #expect(result.environment["SHELL"] == fixture.path())
        }
        #expect(await resolver.resolve().environment["AGENTHESIA_TEST_VALUE"] == "first=second")
        #expect(try Data(contentsOf: counter).count == 1)
    }

    @Test func fallsBackForMissingShell() async {
        let resolver = ShellEnvironment(
            shell: "/missing/agenthesia-shell",
            environment: ["KEEP": "yes", "PATH": "/custom"]
        )
        let result = await resolver.resolve()
        #expect(result.diagnostic != nil)
        #expect(result.environment["KEEP"] == "yes")
        #expect(result.environment["PATH"]?.hasPrefix("/custom:") == true)
        #expect(result.environment["PATH"]?.contains("/usr/bin") == true)
        #expect(result.environment["HOME"] != nil)
    }

    @Test func fallsBackOnTimeout() async throws {
        let fixture = try shell("sleep 5")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(
            shell: fixture.path(),
            environment: ["KEEP": "yes"],
            timeout: .milliseconds(100)
        )
        let result = await resolver.resolve()
        #expect(result.diagnostic?.contains("timed out") == true)
        #expect(result.environment["KEEP"] == "yes")
    }

    @Test func fallsBackWhenOutputExceedsLimit() async throws {
        let fixture = try shell("printf 'many bytes before marker 1234567890\\n'")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(shell: fixture.path(), environment: ["KEEP": "yes"], outputLimit: 12)
        let result = await resolver.resolve()
        #expect(result.diagnostic?.contains("exceeded") == true)
        #expect(result.environment["KEEP"] == "yes")
    }

    @Test func failedParsingIsCachedAndDoesNotRevealOutput() async throws {
        let counter = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-shell-count-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: counter) }
        let fixture = try shell("printf x >> \"$AGENTHESIA_TEST_COUNTER\"; printf 'secret-invalid-output\\n'")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(
            shell: fixture.path(),
            environment: ["KEEP": "yes", "AGENTHESIA_TEST_COUNTER": counter.path()]
        )
        let first = await resolver.resolve()
        let second = await resolver.resolve()
        #expect(first.diagnostic != nil)
        #expect(first.diagnostic?.contains("secret") == false)
        #expect(first.environment["KEEP"] == "yes")
        #expect(second.diagnostic == first.diagnostic)
        #expect(try Data(contentsOf: counter).count == 1)
    }

    @Test func nonzeroExitAndFailedExecFallBack() async throws {
        let exitShell = try shell("exit 7")
        defer { try? FileManager.default.removeItem(at: exitShell.deletingLastPathComponent()) }
        let exited = await ShellEnvironment(shell: exitShell.path(), environment: ["KEEP": "yes"]).resolve()
        #expect(exited.diagnostic != nil)
        #expect(exited.environment["KEEP"] == "yes")

        let brokenShell = try shell("exit 0")
        defer { try? FileManager.default.removeItem(at: brokenShell.deletingLastPathComponent()) }
        try "#!/missing/agenthesia-interpreter\n".write(to: brokenShell, atomically: true, encoding: .utf8)
        let failed = await ShellEnvironment(shell: brokenShell.path(), environment: ["KEEP": "yes"]).resolve()
        #expect(failed.diagnostic?.contains("could not start") == true)
        #expect(failed.environment["KEEP"] == "yes")
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedResolution() async throws {
        let fixture = try shell(
            """
            sleep 0.1
            export AGENTHESIA_TEST_SHARED=yes
            while [ "$#" -gt 0 ]; do
                if [ "$1" = '-c' ]; then shift; eval "$1"; break; fi
                shift
            done
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(shell: fixture.path(), environment: ["PATH": "/usr/bin:/bin"])
        let cancelled = Task { await resolver.resolve() }
        cancelled.cancel()
        let result = await resolver.resolve()
        #expect(result.diagnostic == nil)
        #expect(result.environment["AGENTHESIA_TEST_SHARED"] == "yes")
        _ = await cancelled.value
    }

    @Test func invokesRealLoginShellsWithIsolatedConfiguration() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agenthesia-shell-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let inherited = [
                "HOME": home.path(), "ZDOTDIR": home.path(), "XDG_CONFIG_HOME": home.path(),
                "PATH": "/usr/bin:/bin", "AGENTHESIA_TEST_REAL_SHELL": "a=b",
            ]
            let result = await ShellEnvironment(shell: shell, environment: inherited).resolve()
            #expect(result.diagnostic == nil, "\(shell): \(result.diagnostic ?? "")")
            #expect(result.environment["AGENTHESIA_TEST_REAL_SHELL"] == "a=b")
        }
    }

    @Test func timesOutAndCleansDescendantAfterShellLeaderExits() async throws {
        let childFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-shell-child-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: childFile) }
        let fixture = try shell(
            """
            trap '' TERM
            /bin/sleep 30 &
            echo $! > "$AGENTHESIA_TEST_CHILD_FILE"
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let resolver = ShellEnvironment(
            shell: fixture.path(),
            environment: ["AGENTHESIA_TEST_CHILD_FILE": childFile.path()],
            timeout: .milliseconds(500)
        )
        let result = await resolver.resolve()
        #expect(result.diagnostic?.contains("timed out") == true)
        let pidText = try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        defer { kill(pid, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test(arguments: [false, true])
    func validSnapshotAlsoCleansDescendantHoldingPipe(holdsStdout: Bool) async throws {
        let childFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-shell-stderr-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: childFile) }
        let child = holdsStdout ? "/bin/sleep 30 &" : "/bin/sleep 30 1>&2 &"
        let fixture = try shell(
            """
            trap '' TERM
            \(child)
            echo $! > "$AGENTHESIA_TEST_CHILD_FILE"
            export AGENTHESIA_TEST_VALID=yes
            while [ "$#" -gt 0 ]; do
                if [ "$1" = '-c' ]; then shift; eval "$1"; break; fi
                shift
            done
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let result = await ShellEnvironment(
            shell: fixture.path(),
            environment: ["AGENTHESIA_TEST_CHILD_FILE": childFile.path()]
        ).resolve()
        #expect(result.diagnostic == nil)
        #expect(result.environment["AGENTHESIA_TEST_VALID"] == "yes")
        let pidText = try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        defer { kill(pid, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    private func shell(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agenthesia-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "shell")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path())
        return file
    }
}
