import ACP
import Testing

@testable import AgenthesiaCore

@Suite struct SidebarReasonTests {
    private func text(
        _ activity: LiveSession.Activity,
        signIn: Bool = false,
        permissions: [String?] = [],
        starting: Bool = false,
        stopping: Bool = false,
        merging: Bool = false,
        stopReason: ACP.StopReason? = nil,
        promptFailed: Bool = false,
        queuePaused: Bool = false
    ) -> String? {
        SidebarReason.text(
            activity: activity,
            signIn: signIn,
            permissionTitles: permissions,
            starting: starting,
            stopping: stopping,
            merging: merging,
            stopReason: stopReason,
            promptFailed: promptFailed,
            queuePaused: queuePaused
        )
    }

    @Test func waitingForSignIn() { #expect(text(.needsInput, signIn: true) == "Sign in") }

    @Test func aPendingPermissionNamesTheOldestRequest() {
        #expect(text(.needsInput, permissions: ["Write a.txt"]) == "Allow? Write a.txt")
        #expect(text(.needsInput, permissions: ["Write a.txt", "Run tests", nil]) == "Allow? Write a.txt +2")
        #expect(text(.needsInput, permissions: [nil]) == "Permission")
        #expect(text(.needsInput, permissions: [" \n "]) == "Permission")
        #expect(text(.needsInput, permissions: [nil, "Run tests"]) == "Permission")
    }

    @Test func aPendingFormIsAQuestion() { #expect(text(.needsInput) == "Question") }

    @Test func signInOutranksPermissions() {
        #expect(text(.needsInput, signIn: true, permissions: ["Write a.txt"]) == "Sign in")
    }

    @Test func aFailedSessionFailed() { #expect(text(.failed, promptFailed: true, queuePaused: true) == "Failed") }

    @Test func startingStoppingAndRunning() {
        #expect(text(.working, starting: true) == "Starting")
        #expect(text(.working, stopping: true) == "Stopping")
        #expect(text(.working) == nil)
    }

    @Test func aWorkingRowNamesThePlanStepUnlessAnotherSessionStartedTheTurn() {
        let step = SidebarReason.text(activity: .working, planStep: "Writing tests")
        #expect(step == "Writing tests")
        let origin = SidebarReason.text(activity: .working, turnOrigin: "From Fix CI", planStep: "Writing tests")
        #expect(origin == "From Fix CI")
        #expect(SidebarReason.text(activity: .working, starting: true, planStep: "Writing tests") == "Starting")
        #expect(SidebarReason.text(activity: .idle, planStep: "Writing tests") == nil)
    }

    @Test func mergingAnIdleSession() { #expect(text(.idle, merging: true, queuePaused: true) == "Merging") }

    @Test func aFinishedTurnSaysHowItEnded() {
        #expect(text(.done, stopReason: .endTurn) == "Finished")
        #expect(text(.done, stopReason: .refusal) == "Refused")
        #expect(text(.done, stopReason: .maxTokens) == "Hit a limit")
        #expect(text(.done, stopReason: .maxTurnRequests) == "Hit a limit")
        #expect(text(.done, stopReason: .unknown("future")) == "Finished")
        #expect(text(.done) == "Finished")
    }

    @Test func anIdleSessionExplainsAStalledQueueOrAFailedPrompt() {
        #expect(text(.idle, promptFailed: true, queuePaused: true) == "Prompt failed")
        #expect(text(.idle, queuePaused: true) == "Queue paused")
        #expect(text(.idle) == nil)
    }

    @Test func titlesKeepTheirFirstLineWithWhitespaceCollapsed() {
        #expect(SidebarReason.displayTitle("Write  a.txt\n\twith secrets\nmore") == "Write a.txt")
        #expect(SidebarReason.displayTitle("\n  Run\ttests \r\n second") == "Run tests")
        #expect(SidebarReason.displayTitle("") == nil)
        #expect(SidebarReason.displayTitle(" \n\t ") == nil)
    }

    @Test func titlesAreCappedAt120Characters() throws {
        let exact = String(repeating: "a", count: 120)
        #expect(SidebarReason.displayTitle(exact) == exact)
        let capped = try #require(SidebarReason.displayTitle(exact + "b"))
        #expect(capped.count == 120 && capped.hasSuffix("…") && capped.hasPrefix(String(repeating: "a", count: 119)))
        let reason = text(.needsInput, permissions: [String(repeating: "word ", count: 100) + "\nsecond line"])
        #expect(reason?.count == "Allow? ".count + 120)
        #expect(reason?.contains("second") == false)
    }

    @Test func anArchivedSessionSaysSoAndOtherwiseKeepsItsOutcome() {
        #expect(SidebarReason.saved(archived: true, outcome: nil) == "Archived")
        #expect(SidebarReason.saved(archived: true, outcome: "Merged") == "Archived")
        #expect(SidebarReason.saved(archived: false, outcome: "Merged") == "Merged")
        #expect(SidebarReason.saved(archived: false, outcome: nil) == nil)
    }
}
