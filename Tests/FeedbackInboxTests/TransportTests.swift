import Foundation
import Testing
@testable import FeedbackInbox

struct TransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FEEDBACK_TRANSPORT_TEST_ORIGIN"] != nil))
    func realHTTPKeepsEnrollmentBodyAwayFromRedirectTarget() async throws {
        let origin = try #require(ProcessInfo.processInfo.environment["FEEDBACK_TRANSPORT_TEST_ORIGIN"].flatMap(URL.init(string:)))
        let target = try #require(ProcessInfo.processInfo.environment["FEEDBACK_TRANSPORT_TEST_TARGET"].flatMap(URL.init(string:)))
        let configuration = try InboxClient.Configuration(serverURL: URL(string: "https://unused.example.test")!, appID: "com.example.transport")
        let io = ClientIO.live(configuration: configuration)
        var request = URLRequest(url: origin.appendingPathComponent("redirect"))
        request.httpMethod = "POST"; request.httpBody = Data("disposable-enrollment-fixture".utf8)
        request.setValue("Bearer disposable-fixture", forHTTPHeaderField: "Authorization")
        let rejected = try await io.exchange(request)
        #expect(rejected.status == 307)
        request.url = origin.appendingPathComponent("direct")
        #expect(try await io.exchange(request).status == 200)
        let (data, _) = try await URLSession.shared.data(from: target.appendingPathComponent("count"))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(counts["targetHits"] == 0)
    }
}
