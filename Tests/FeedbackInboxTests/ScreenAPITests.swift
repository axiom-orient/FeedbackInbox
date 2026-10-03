import Foundation
import SwiftUI
import Testing
import FeedbackInbox

@MainActor struct ScreenAPITests {
    @Test func anotherAppCanUseTheCompletePublicScreenWithOneConfiguration() throws {
        let configuration = try InboxClient.Configuration(serverURL: URL(string: "https://other.example.test")!, appID: "com.axionorient.other")
        _ = InboxView(configuration: configuration)
        _ = InboxView(serverURL: URL(string: "https://support.example.test")!, navigation: .embedded)
        _ = InboxScreen(state: .init()) { _ in }
    }
}
