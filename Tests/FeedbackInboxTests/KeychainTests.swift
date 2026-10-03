import Foundation
import Security
import Testing
@testable import FeedbackInbox

struct KeychainTests {
    @Test func actualKeychainSharesCredentialsFreezesPendingAndProtectsNewerWrite() throws {
        let service="com.axionorient.feedback-package-tests."+UUID().uuidString
        defer {SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service] as CFDictionary)}
        let first=KeychainStorage(service:service).clientStorage, second=KeychainStorage(service:service).clientStorage
        let credential=try first.credential();#expect(try second.credential() == credential)
        let context=InboxClient.ClientContext(appID:"com.axionorient.test",appVersion:"1.0")
        let request=InboxClient.PendingSend(kind:.reply,threadID:UUID(),messageID:UUID(),body:"원문")
        let saved=try first.admit(request,context)
        #expect(try second.admit(request,InboxClient.ClientContext(appID:"com.axionorient.test",appVersion:"2.0")) == saved)
        #expect(try second.pending() == saved)
        let next=InboxClient.PendingSend(kind:.reply,threadID:request.threadID,messageID:UUID(),body:"다음 원문")
        #expect(throws:InboxClient.Failure.pendingSendConflict){try second.admit(next,context)}
        try first.clear(saved);_ = try second.admit(next,context)
        try first.clear(saved)
        #expect(try second.pending()?.messageID == next.messageID)
        try second.clear(try #require(try second.pending()));#expect(try first.pending() == nil)
    }
    @Test func corruptStoredStateIsAnErrorNotAFreshIdentity() throws {
        let service="com.axionorient.feedback-package-tests."+UUID().uuidString
        defer {SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service] as CFDictionary)}
        let item:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"installation",kSecValueData as String:Data("broken json".utf8)]
        #expect(SecItemAdd(item as CFDictionary,nil) == errSecSuccess)
        #expect(throws:InboxClient.Failure.invalidStoredState){try KeychainStorage(service:service).clientStorage.credential()}
    }
}
