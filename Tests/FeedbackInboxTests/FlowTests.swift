import Foundation
import Testing
@testable import FeedbackInbox

struct FlowTests {
    private let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    @Test func emptySuccessAndFailureDoNotShareTheSameMeaning() {
        var state = InboxFlow.State()
        let commands = InboxFlow.reduce(&state, .appeared, makeID: { id })
        #expect(commands == [.cancelRead, .inbox(id)])
        #expect(state.availability == .initial)
        _ = InboxFlow.reduce(&state, .inboxLoaded(id, .success(.init(page: .init(threads: [], nextBefore: nil), pending: nil))), makeID: { id })
        #expect(state.isReady && state.threads.isEmpty)
        var failure = InboxFlow.State(); failure.isVisible = true; failure.activity = .reading(id)
        _ = InboxFlow.reduce(&failure, .inboxFailed(id, .transport(code: -1009), nil), makeID: { id })
        #expect(!failure.isReady); #expect(failure.failure == .transport(code: -1009))
    }
    @Test func staleReadsAndDismissalCannotReplaceTheCurrentRoute() {
        var state = InboxFlow.State(); state.isVisible = true; state.activity = .reading(id)
        state.route = .conversation(UUID())
        let old = UUID(), thread = InboxClient.Thread(id: old, status: .open, createdAt: 1, updatedAt: 1, preview: "old")
        _ = InboxFlow.reduce(&state, .conversationLoaded(id, old, false, .success(.init(thread: thread, messages: []))), makeID: { id })
        #expect(state.conversation == nil)
        _ = InboxFlow.reduce(&state, .disappeared, makeID: { id })
        _ = InboxFlow.reduce(&state, .inboxLoaded(id, .success(.init(page: .init(threads: [], nextBefore: nil), pending: nil))), makeID: { id })
        #expect(!state.isReady); #expect(state.activity == .idle)
    }
    @Test func composerAndReplyDraftsSurviveRouteChanges() {
        var state = InboxFlow.State(); state.availability = .ready
        _ = InboxFlow.reduce(&state, .compose, makeID: { id })
        _ = InboxFlow.reduce(&state, .draftChanged("내 문의 초안"), makeID: { id })
        _ = InboxFlow.reduce(&state, .back, makeID: { id })
        state.activity = .idle
        _ = InboxFlow.reduce(&state, .compose, makeID: { id })
        #expect(state.draft == "내 문의 초안")
        state.route = .conversation(id); state.activity = .idle
        _ = InboxFlow.reduce(&state, .draftChanged("답변 초안"), makeID: { id })
        _ = InboxFlow.reduce(&state, .back, makeID: { id }); state.activity = .idle
        _ = InboxFlow.reduce(&state, .open(id), makeID: { id })
        #expect(state.draft == "답변 초안")
    }
    @Test func coldOfflinePendingIsVisibleAndCanReconcileWithoutPretendingReady() {
        let pending = InboxClient.PendingSend(kind: .reply, threadID: id, messageID: UUID(), body: "미확인 원문")
        var state = InboxFlow.State(); state.isVisible = true; state.activity = .reading(id)
        _ = InboxFlow.reduce(&state, .inboxFailed(id, .transport(code: -1009), pending), makeID: { id })
        #expect(!state.isReady); #expect(state.draft == pending.body); #expect(state.canSend)
        let commands = InboxFlow.reduce(&state, .send, makeID: { id })
        #expect(commands == [.cancelRead, .send(id, pending)])
        _ = InboxFlow.reduce(&state, .sent(id, pending, .failure(.cancelled)), makeID: { id })
        #expect(state.pending == pending); #expect(state.draft == pending.body)
    }
    @Test func previousPagesMergeByIdentityWithoutLosingDrafts() {
        let thread = InboxClient.Thread(id: id, status: .open, createdAt: 1, updatedAt: 3, preview: "문의")
        let first = InboxClient.Message(id: UUID(), sequence: 1, sender: .user, body: "문의", createdAt: 1)
        let last = InboxClient.Message(id: UUID(), sequence: 3, sender: .operator, body: "답변", createdAt: 3)
        var state = InboxFlow.State(); state.isVisible = true; state.route = .conversation(id); state.activity = .reading(id)
        state.replyDrafts[id] = "작성 중"; state.conversation = .init(thread: thread, messages: [last], previousBefore: 3)
        _ = InboxFlow.reduce(&state, .conversationLoaded(id, id, true, .success(.init(thread: thread, messages: [first, last]))), makeID: { id })
        #expect(state.conversation?.messages == [first, last]); #expect(state.draft == "작성 중")
    }
    @Test func successfulThreadPageRetryClearsThePreviousReadFailure() {
        let first = InboxClient.Thread(id: id, status: .open, createdAt: 3, updatedAt: 3, preview: "새 문의")
        let older = InboxClient.Thread(id: UUID(), status: .open, createdAt: 1, updatedAt: 1, preview: "이전 문의")
        var state = InboxFlow.State(); state.isVisible = true; state.availability = .ready
        state.threads = [first]; state.nextBefore = "older"
        _ = InboxFlow.reduce(&state, .moreThreads, makeID: { id })
        _ = InboxFlow.reduce(&state, .threadsLoaded(id, .failure(.transport(code: -1009))), makeID: { id })
        #expect(state.failure != nil); #expect(state.threads == [first])
        _ = InboxFlow.reduce(&state, .moreThreads, makeID: { id })
        _ = InboxFlow.reduce(&state, .threadsLoaded(id, .success(.init(threads: [older], nextBefore: nil))), makeID: { id })
        #expect(state.failure == nil); #expect(state.threads == [first, older]); #expect(state.activity == .idle)
    }
    @Test func definitiveRejectionPreservesDraftAndUpdatesClosedAvailability() {
        let pending = InboxClient.PendingSend(kind: .reply, threadID: id, messageID: UUID(), body: "원문")
        var state = InboxFlow.State(); state.route = .conversation(id); state.activity = .writing(id); state.availability = .ready
        state.pending = pending; state.replyDrafts[id] = pending.body
        state.conversation = .init(thread: .init(id: id, status: .open, createdAt: 1, updatedAt: 1, preview: "문의"), messages: [])
        _ = InboxFlow.reduce(&state, .sent(id, pending, .failure(.server(status: 409, code: "thread_closed"))), makeID: { id })
        #expect(state.pending == nil); #expect(state.draft == pending.body); #expect(state.conversation?.thread.status == .closed)
        #expect(!state.canSend)
    }
    @Test func lateCommittedWriteRetainsItsReceiptAfterDismissal() throws {
        let pending = InboxClient.PendingSend(kind: .newThread, threadID: id, messageID: UUID(), body: "원문")
        let message = InboxClient.Message(id: pending.messageID, sequence: 1, sender: .user, body: pending.body, createdAt: 1)
        let thread = InboxClient.Thread(id: id, status: .open, createdAt: 1, updatedAt: 1, preview: pending.body)
        let receipt = InboxClient.Receipt(thread: thread, message: message)
        var state = InboxFlow.State(); state.route = .compose; state.activity = .writing(id); state.pending = pending; state.newDraft = pending.body
        _ = InboxFlow.reduce(&state, .disappeared, makeID: { id })
        _ = InboxFlow.reduce(&state, .sent(id, pending, .success(receipt)), makeID: { id })
        #expect(state.pending == nil); #expect(state.conversation?.messages == [message]); #expect(state.newDraft.isEmpty)
        #expect(!state.isVisible)
    }
    @Test func confirmedReplySurvivesColdTranscriptRefreshFailure() {
        let pending = InboxClient.PendingSend(kind: .reply, threadID: id, messageID: UUID(), body: "서버에 저장할 원문")
        let message = InboxClient.Message(id: pending.messageID, sequence: 2, sender: .user, body: pending.body, createdAt: 1)
        var state = InboxFlow.State(); state.isVisible = true; state.route = .conversation(id)
        state.activity = .writing(id); state.pending = pending
        let commands = InboxFlow.reduce(&state, .sent(id, pending, .success(.init(thread: nil, message: message))), makeID: { id })
        #expect(commands == [.cancelRead, .conversation(id, id, nil, false)])
        _ = InboxFlow.reduce(&state, .conversationLoaded(id, id, false, .failure(.transport(code: -1009))), makeID: { id })
        #expect(state.lastCommit?.message == message); #expect(state.pending == nil)
        #expect(state.issue == .read(.transport(code: -1009)))
    }

    @Test func coldRestoredDefinitiveRejectionKeepsAnEditableBackingDraft() {
        for kind in [InboxClient.PendingSend.Kind.newThread, .reply] {
            let pending = InboxClient.PendingSend(kind: kind, threadID: id, messageID: UUID(), body: "복원한 문의 원문")
            var state = InboxFlow.State(); state.isVisible = true; state.activity = .reading(id)
            _ = InboxFlow.reduce(&state, .inboxFailed(id, .transport(code: -1009), pending), makeID: { id })
            _ = InboxFlow.reduce(&state, .send, makeID: { id })
            _ = InboxFlow.reduce(&state, .sent(id, pending, .failure(.server(status: 429, code: "daily_thread_limit"))), makeID: { id })
            #expect(state.pending == nil); #expect(state.draft == pending.body)
            _ = InboxFlow.reduce(&state, .draftChanged("수정한 내용"), makeID: { id })
            #expect(state.draft == "수정한 내용")
        }
    }

}
