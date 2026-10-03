import Foundation
import Testing
@testable import FeedbackInbox

private let context = InboxClient.ClientContext(appName:"Test",appID:"com.axionorient.sumday",appVersion:"1.0",appBuild:"1",osName:"iOS",osVersion:"26.5",deviceModel:"iPhone",language:"ko-KR")
private let request = InboxClient.PendingSend(kind:.newThread,threadID:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,messageID:UUID(uuidString:"22222222-2222-2222-2222-222222222222")!,body:"문의 원문")

// Injected adapter tests own failure/state semantics; not proof of live HTTP or OS persistence.
final class MemoryStore: @unchecked Sendable {
    private let lock=NSLock()
    private var value: InboxClient.PendingSend?
    var failClear=false
    let identity=Credential(id:UUID(uuidString:"33333333-3333-3333-3333-333333333333")!,secret:String(repeating:"a",count:64))
    var storage: ClientStorage {
        ClientStorage(credential:{self.identity},pending:{self.read()},admit:{ candidate, context in
            self.lock.lock();defer{self.lock.unlock()}
            if let value=self.value {guard value.matchesForRetry(candidate) else{throw InboxClient.Failure.pendingSendConflict};return value}
            var snapshot=candidate;if snapshot.clientContext == nil{snapshot.clientContext=context};self.value=snapshot;return snapshot
        },clear:{ candidate in
            self.lock.lock();defer{self.lock.unlock()}
            if self.failClear {throw InboxClient.Failure.storage(status:-1)}
            if self.value == candidate {self.value=nil}
        })
    }
    func read()->InboxClient.PendingSend? {lock.lock();defer{lock.unlock()};return value}
    func seed(_ pending: InboxClient.PendingSend){lock.lock();defer{lock.unlock()};value=pending}
}
private func configuration() throws -> InboxClient.Configuration {
    try .init(serverURL:URL(string:"https://support.example.test")!,appID:"com.axionorient.sumday")
}
private func registration(_ store:MemoryStore)throws->HTTPResult {HTTPResult(data:try JSONEncoder().encode(["id":store.identity.id.uuidString]),status:201)}
private struct WireReceipt: Encodable {let thread:InboxClient.Thread?;let message:InboxClient.Message}
private func receipt(_ snapshot:InboxClient.PendingSend,altered:Bool=false)throws->HTTPResult {
    let thread=InboxClient.Thread(id:snapshot.threadID,status:.open,createdAt:1,updatedAt:1,preview:snapshot.body)
    let message=InboxClient.Message(id:altered ? UUID():snapshot.messageID,sequence:1,sender:.user,body:snapshot.body,createdAt:1,clientContext:snapshot.clientContext)
    return HTTPResult(data:try JSONEncoder().encode(WireReceipt(thread:snapshot.kind == .newThread ? thread:nil,message:message)),status:201)
}
private actor RequestLog {
    var requests:[URLRequest]=[]
    func append(_ r:URLRequest){requests.append(r)}
}
private actor Gate {
    private var started=false
    private var startWaiters:[CheckedContinuation<Void,Never>]=[]
    private var release:CheckedContinuation<Void,Never>?
    func block()async {started=true;for waiter in startWaiters{waiter.resume()};startWaiters=[];await withCheckedContinuation{release=$0}}
    func waitForStart()async {if started{return};await withCheckedContinuation{startWaiters.append($0)}}
    func finish(){release?.resume();release=nil}
}

struct ClientTests {
    @Test func successFreezesContextAndClearsOnlyCommittedRequest()async throws {
        let store=MemoryStore(),log=RequestLog()
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            await log.append(r)
            if r.url?.path == "/installations"{return try registration(store)}
            return try receipt(#require(store.read()))
        }))
        let saved=try await client.send(request)
        #expect(saved.message.body == request.body);#expect(saved.message.clientContext == context)
        #expect(try await client.pendingSend() == nil);#expect(await client.phase == .idle)
        let sent=await log.requests
        #expect(sent.count == 2);#expect(sent[1].value(forHTTPHeaderField:"Authorization") == "Bearer \(store.identity.id.uuidString.lowercased()):\(store.identity.secret)")
        let body=try #require(sent[1].httpBody)
        let encoded=try #require(JSONSerialization.jsonObject(with:body) as? [String:Any])
        #expect(encoded["messageID"] as? String == request.messageID.uuidString)
    }
    @Test func lostResponseRestartsWithExactPersistedSnapshotAndIDs()async throws {
        let store=MemoryStore()
        let first=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(store)}
            throw URLError(.networkConnectionLost)
        }))
        await #expect(throws:InboxClient.Failure.transport(code:URLError.networkConnectionLost.rawValue)){try await first.send(request)}
        let pending=try #require(store.read());#expect(pending.clientContext == context)
        let updated=InboxClient.ClientContext(appID:context.appID,appVersion:"2.0",osName:"iOS",osVersion:"27.0")
        let restarted=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{updated},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(store)}
            return try receipt(#require(store.read()))
        }))
        let saved=try await restarted.send(request)
        #expect(saved.message.id == pending.messageID);#expect(saved.message.clientContext == context)
    }
    @Test func definitiveServerRejectionReleasesDraftButUnknownServerErrorDoesNot()async throws {
        for (status,code,definitive) in [(429,"daily_thread_limit",true),(503,"invalid_message",false),(409,"id_conflict",false)] {
            let store=MemoryStore()
            let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
                if r.url?.path == "/installations"{return try registration(store)}
                return HTTPResult(data:try JSONEncoder().encode(["error":code]),status:status)
            }))
            await #expect(throws:InboxClient.Failure.server(status:status,code:code)){try await client.send(request)}
            #expect((store.read() == nil) == definitive);#expect(await client.phase == .idle)
        }
    }
    @Test func confirmedReceiptSurvivesCleanupFailure()async throws {
        let store=MemoryStore();store.failClear=true
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(store)}
            return try receipt(#require(store.read()))
        }))
        let saved=try await client.send(request)
        #expect(saved.message.id == request.messageID);#expect(saved.persistenceIssue == .storage(status:-1))
        #expect(store.read()?.messageID == request.messageID)
    }
    @Test func differentWriteCannotReplaceUncertainBodyOrRunDuringAdmission()async throws {
        let store=MemoryStore(),gate=Gate()
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(store)}
            await gate.block();throw URLError(.networkConnectionLost)
        }))
        let send=Task{try await client.send(request)}
        await gate.waitForStart()
        let changed=InboxClient.PendingSend(kind:.newThread,threadID:request.threadID,messageID:request.messageID,body:"다른 원문")
        await #expect(throws:InboxClient.Failure.writeInProgress){try await client.send(changed)}
        #expect(await client.phase == .sending(try #require(store.read())))
        await gate.finish();_ = await send.result
        await #expect(throws:InboxClient.Failure.pendingSendConflict){try await client.send(changed)}
        #expect(store.read()?.body == request.body)
    }
    @Test func cancellationKeepsAdmittedWriteForExplicitRetry()async throws {
        let store=MemoryStore(),gate=Gate()
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(store)}
            await gate.block();try Task.checkCancellation();throw URLError(.networkConnectionLost)
        }))
        let work=Task{try await client.send(request)};await gate.waitForStart();work.cancel();await gate.finish()
        await #expect(throws:InboxClient.Failure.cancelled){try await work.value}
        #expect(store.read()?.messageID == request.messageID);#expect(await client.phase == .idle)
    }
    @Test func mismatchedReceiptAndMalformedJSONDoNotClearPending()async throws {
        for malformed in [true,false] {
            let store=MemoryStore()
            let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
                if r.url?.path == "/installations"{return try registration(store)}
                return malformed ? HTTPResult(data:Data("broken json".utf8),status:200):try receipt(#require(store.read()),altered:true)
            }))
            await #expect(throws:InboxClient.Failure.invalidResponse){try await client.send(request)}
            #expect(store.read() != nil)
        }
    }
    @Test func latestAndOlderRequestsKeepExplicitCursorAndThread()async throws {
        let store=MemoryStore(),log=RequestLog()
        let thread=InboxClient.Thread(id:request.threadID,status:.open,createdAt:1,updatedAt:2,preview:"문의")
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in
            await log.append(r);if r.url?.path == "/installations"{return try registration(store)}
            return HTTPResult(data:try JSONEncoder().encode(InboxClient.Conversation(thread:thread,messages:[],previousBefore:7)),status:200)
        }))
        _ = try await client.conversation(thread.id);_ = try await client.conversation(thread.id,before:7)
        await #expect(throws:InboxClient.Failure.invalidCursor){try await client.conversation(thread.id,before:0)}
        let calls=await log.requests;#expect(calls[1].url?.query == "latest=1");#expect(calls[2].url?.query == "before=7")
    }
    @Test func invalidContextAndMessageNeverEnterTransport()async throws {
        let store=MemoryStore(),log=RequestLog()
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{InboxClient.ClientContext(appID:"com.axionorient.other")},exchange:{ r in await log.append(r);throw URLError(.badURL)}))
        await #expect(throws:InboxClient.Failure.invalidContext){try await client.send(request)}
        #expect(store.read() == nil);#expect(await log.requests.isEmpty)
        let invalid=InboxClient.PendingSend(kind:.reply,threadID:request.threadID,messageID:request.messageID,body:" \n")
        await #expect(throws:InboxClient.Failure.invalidMessage){try await client.send(invalid)}
    }
    @Test func escapedPayloadLimitAndRejectionCleanupFailureStayExplicit() async throws {
        let store=MemoryStore(),log=RequestLog()
        let client=InboxClient(configuration:try configuration(),io:ClientIO(storage:store.storage,context:{context},exchange:{ r in await log.append(r);throw URLError(.badURL)}))
        let large=InboxClient.PendingSend(kind:.newThread,threadID:request.threadID,messageID:request.messageID,body:String(repeating:"\u{0000}",count:5000))
        await #expect(throws:InboxClient.Failure.payloadTooLarge){try await client.send(large)}
        #expect(store.read() == nil);#expect(await log.requests.isEmpty)
        let rejectedStore=MemoryStore();rejectedStore.failClear=true
        let rejected=InboxClient(configuration:try configuration(),io:ClientIO(storage:rejectedStore.storage,context:{context},exchange:{ r in
            if r.url?.path == "/installations"{return try registration(rejectedStore)}
            return HTTPResult(data:Data(#"{"error":"thread_closed"}"#.utf8),status:409)
        }))
        await #expect(throws:InboxClient.Failure.cleanupFailed(rejection:"thread_closed",status:-1)){try await rejected.send(request)}
        #expect(rejectedStore.read() != nil)
    }

}
