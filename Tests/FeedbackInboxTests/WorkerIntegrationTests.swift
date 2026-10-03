import Foundation
import Testing
@testable import FeedbackInbox

struct WorkerIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FEEDBACK_SDK_TEST_URL"] != nil))
    func actualWorkerReceiptsRecoverAfterResponseLossAndKeepOtherAppContext() async throws {
        let base=try #require(ProcessInfo.processInfo.environment["FEEDBACK_SDK_TEST_URL"].flatMap(URL.init(string:)))
        let store=MemoryStore()
        // Isolated live Worker configured as this different app. Context/storage are test adapters;
        // POST/receipt/read/idempotence run against real Worker+D1, not handler/DB mocks.
        let identity=Credential(id:UUID(),secret:String(repeating:"b",count:64))
        var storage=store.storage;storage.credential={identity}
        let context=InboxClient.ClientContext(appName:"Other",appID:"com.axionorient.other",appVersion:"3.0",appBuild:"5",osName:"iOS",osVersion:"26.5",deviceModel:"iPhone",language:"ko-KR")
        let configuration=try InboxClient.Configuration(serverURL:URL(string:"https://support.example.test")!,appID:"com.axionorient.other")
        let gate=LossGate()
        let io=ClientIO(storage:storage,context:{context},exchange:{ request in
            var live=request
            let path=try #require(request.url?.path)
            var url=try #require(URLComponents(url:base.appendingPathComponent(String(path.dropFirst())),resolvingAgainstBaseURL:false))
            url.query=request.url?.query;live.url=url.url
            let (data,response)=try await URLSession.shared.data(for:live)
            let http=try #require(response as? HTTPURLResponse)
            if path == "/threads",request.httpMethod == "POST", await gate.shouldLose() {throw URLError(.networkConnectionLost)}
            return HTTPResult(data:data,status:http.statusCode)
        })
        let pending=InboxClient.PendingSend(kind:.newThread,threadID:UUID(),messageID:UUID(),body:"다른 앱 SDK 실제 연결 시험")
        let first=InboxClient(configuration:configuration,io:io)
        await #expect(throws:InboxClient.Failure.transport(code:URLError.networkConnectionLost.rawValue)){try await first.send(pending)}
        let restarted=InboxClient(configuration:configuration,io:io)
        let saved=try await restarted.send(pending)
        #expect(saved.message.id == pending.messageID);#expect(saved.message.clientContext == context)
        let page=try await restarted.conversation(pending.threadID)
        #expect(page.messages.count == 1);#expect(page.messages[0].id == pending.messageID)
        #expect(try await restarted.inbox().page.threads.count == 1)
        // Replay even after the local pending identity was cleared; server returns same message.
        let replay=try await restarted.send(pending);#expect(replay.message == saved.message)
    }
}
private actor LossGate {var lose=true;func shouldLose()->Bool{defer{lose=false};return lose}}
