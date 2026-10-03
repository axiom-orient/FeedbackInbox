import Foundation
import Testing
import FeedbackInbox

struct CoreTests {
    @Test func publicAPIExampleHasNoSumdayOrTCAImport()async throws {
        let configuration=try InboxClient.Configuration(serverURL:URL(string:"https://other-feedback.example.test")!,appID:"com.axionorient.other")
        let client=InboxClient(configuration:configuration)
        #expect(await client.phase == .idle)
        let pending=InboxClient.PendingSend(kind:.newThread,threadID:UUID(),messageID:UUID(),body:"질문")
        #expect(InboxClient.Policy.accepts(pending.body));#expect(configuration.appID == "com.axionorient.other")
    }
    @Test func unicodeScalarBoundariesAndInvalidConfiguration() throws {
        #expect(InboxClient.Policy.accepts(String(repeating:"가",count:5000)))
        #expect(!InboxClient.Policy.accepts(String(repeating:"가",count:5001)))
        #expect(!InboxClient.Policy.accepts(" \n\t"))
        #expect(InboxClient.Policy.accepts(String(repeating:"e\u{301}",count:2500)))
        for url in ["http://example.test","https://example.test/path","https://user:secret@example.test","https://example.test?x=1","https://example.test/#x"] {
            #expect(throws:InboxClient.Failure.invalidConfiguration){try InboxClient.Configuration(serverURL:URL(string:url)!,appID:"com.axionorient.other")}
        }
    }
    @Test func existingPendingFormatPreservesUnknownHistoricalContext() throws {
        let data=Data(#"{"kind":"reply","threadID":"11111111-1111-1111-1111-111111111111","messageID":"22222222-2222-2222-2222-222222222222","body":"원문"}"#.utf8)
        let pending=try JSONDecoder().decode(InboxClient.PendingSend.self,from:data)
        #expect(pending.clientContext == nil);#expect(pending.body == "원문")
        #expect(try JSONDecoder().decode(InboxClient.PendingSend.self,from:JSONEncoder().encode(pending)) == pending)
    }
    @Test func appIdentityMatchesTheServerAdmissionBoundary() throws {
        let url = URL(string: "https://support.example.test")!
        _ = try InboxClient.Configuration(serverURL: url, appID: String(repeating: "a", count: 128))
        for appID in ["", "ab", "-com.example", "앱.example", "com.example\n", String(repeating: "a", count: 129)] {
            #expect(throws: InboxClient.Failure.invalidConfiguration) { try InboxClient.Configuration(serverURL: url, appID: appID) }
        }
    }
    @Test func canonicallyEquivalentEditedTextDoesNotCountAsExactRetry() {
        let id=UUID(), message=UUID()
        let composed=InboxClient.PendingSend(kind:.reply,threadID:id,messageID:message,body:"é")
        let decomposed=InboxClient.PendingSend(kind:.reply,threadID:id,messageID:message,body:"e\u{301}")
        #expect(composed.body == decomposed.body)
        #expect(!composed.matchesForRetry(decomposed))
    }

}
