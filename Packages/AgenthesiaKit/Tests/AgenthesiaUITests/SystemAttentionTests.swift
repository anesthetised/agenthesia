import Foundation
import Persistence
import Testing
import UserNotifications

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct SystemAttentionTests {
    private typealias Payload = SystemAttention.Payload

    private func notice(_ kind: AttentionNotice.Kind) -> AttentionNotice {
        .init(id: "n", sessionID: UUID(), kind: kind, title: "Title", body: "Body")
    }

    @Test func sessionURLsRoundTripAndOnlyWellFormedOnesAreAccepted() throws {
        let id = UUID()
        let url = try #require(WindowTarget.session(id).url)
        #expect(url.absoluteString == "agenthesia://session/\(id.uuidString)")
        #expect(WindowTarget(url: url) == .session(id))
        #expect(WindowTarget.launch.url == nil)
        for text in [
            "https://session/\(id.uuidString)", "agenthesia://other/\(id.uuidString)", "agenthesia://session",
            "agenthesia://session/not-a-uuid", "agenthesia://session/\(id.uuidString)/extra",
        ] {
            #expect(WindowTarget(url: try #require(URL(string: text))) == nil, "\(text)")
        }
    }

    @Test func permissionNoticesCarryButtonsOnlyWhenTheyCanDecide() {
        let request = UUID()
        let decidable = notice(.permission(requestID: request, canDecide: true))
        let payload = Payload(decidable)
        #expect(payload.category == Payload.decisionCategory)
        #expect(payload.userInfo == ["session": decidable.sessionID.uuidString, "request": request.uuidString])
        #expect(payload.sound && payload.title == "Title" && payload.body == "Body")
        #expect(Payload(notice(.permission(requestID: request, canDecide: false))).category == nil)
    }

    @Test func otherNoticesHaveNoButtonsAndOnlyAFinishedTurnIsSilent() {
        let request = UUID()
        let input = Payload(notice(.input(requestID: request)))
        #expect(input.category == nil && input.sound && input.userInfo["request"] == request.uuidString)
        let failure = Payload(notice(.failure))
        #expect(failure.category == nil && failure.sound && failure.userInfo["request"] == nil)
        let finished = Payload(notice(.finished))
        #expect(finished.category == nil && !finished.sound)
    }

    @Test func tapsOpenTheSessionAndButtonsAnswerTheirRequest() {
        let session = UUID()
        let request = UUID()
        let info = ["session": session.uuidString, "request": request.uuidString]
        #expect(
            Payload.route(action: UNNotificationDefaultActionIdentifier, userInfo: info)
                == .open(sessionID: session)
        )
        #expect(
            Payload.route(action: Payload.allow, userInfo: info)
                == .decide(sessionID: session, requestID: request, allow: true)
        )
        #expect(
            Payload.route(action: Payload.reject, userInfo: info)
                == .decide(sessionID: session, requestID: request, allow: false)
        )
        #expect(Payload.route(action: UNNotificationDismissActionIdentifier, userInfo: info) == nil)
        #expect(Payload.route(action: "other", userInfo: info) == nil)
        #expect(Payload.route(action: Payload.allow, userInfo: ["session": session.uuidString]) == nil)
        #expect(Payload.route(action: UNNotificationDefaultActionIdentifier, userInfo: [:]) == nil)
        #expect(Payload.route(action: UNNotificationDefaultActionIdentifier, userInfo: ["session": "x"]) == nil)
    }
}
