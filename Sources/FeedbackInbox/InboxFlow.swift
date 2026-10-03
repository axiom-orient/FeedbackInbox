import Foundation

/// Deterministic UI state shared by the packaged screen and consumer reducer adapters.
public enum InboxFlow {
    public enum Route: Equatable, Sendable { case inbox, compose, conversation(UUID) }
    public enum Availability: Equatable, Sendable { case initial, ready, blocked }
    public enum Activity: Equatable, Sendable { case idle, reading(UUID), writing(UUID) }
    public enum Issue: Equatable, Sendable {
        case read(InboxClient.Failure), send(InboxClient.Failure)
        public var failure: InboxClient.Failure { switch self { case let .read(value), let .send(value): value } }
    }
    public struct Commit: Equatable, Sendable { public let threadID: UUID; public let message: InboxClient.Message }
    public struct State: Equatable, Sendable {
        public var isVisible = false
        public var availability: Availability = .initial
        public var activity: Activity = .idle
        public var route: Route = .inbox
        public var threads: [InboxClient.Thread] = []
        public var nextBefore: String?
        public var conversation: InboxClient.Conversation?
        public var newDraft = ""
        public var replyDrafts: [UUID: String] = [:]
        public var pending: InboxClient.PendingSend?
        public var issue: Issue?
        public var lastCommit: Commit?
        public var failure: InboxClient.Failure? { issue?.failure }
        public var persistenceIssue: InboxClient.Failure?
        public init() {}
        public var selectedThreadID: UUID? { if case let .conversation(id) = route { return id }; return nil }
        public var isComposing: Bool { route == .compose }
        public var isReady: Bool { availability == .ready }
        public var readID: UUID? { if case let .reading(id) = activity { return id }; return nil }
        public var isWriting: Bool { if case .writing = activity { return true }; return false }
        public var draft: String {
            get { if let pending { return pending.body }; return switch route { case .compose: newDraft; case let .conversation(id): replyDrafts[id] ?? ""; case .inbox: "" } }
            set { switch route { case .compose: newDraft = newValue; case let .conversation(id): replyDrafts[id] = newValue; case .inbox: break } }
        }
        public var canSend: Bool {
            activity == .idle && (pending != nil || (isReady && InboxClient.Policy.accepts(draft)
                && (isComposing || conversation?.thread.status == .open)))
        }
    }
    public enum Action: Equatable, Sendable {
        case appeared, disappeared, refresh, moreThreads, moreMessages, compose, back
        case open(UUID), draftChanged(String), send
        case inboxLoaded(UUID, Result<InboxClient.Snapshot, InboxClient.Failure>)
        case inboxFailed(UUID, InboxClient.Failure, InboxClient.PendingSend?)
        case threadsLoaded(UUID, Result<InboxClient.ThreadPage, InboxClient.Failure>)
        case conversationLoaded(UUID, UUID, Bool, Result<InboxClient.Conversation, InboxClient.Failure>)
        case sent(UUID, InboxClient.PendingSend, Result<InboxClient.Receipt, InboxClient.Failure>)
    }
    public enum Command: Equatable, Sendable {
        case cancelRead
        case inbox(UUID), threads(UUID, String), conversation(UUID, UUID, Int?, Bool)
        case send(UUID, InboxClient.PendingSend)
        public var readID: UUID? {
            switch self { case let .inbox(id), let .threads(id,_), let .conversation(id,_,_,_): id; default: nil }
        }
    }
    public static func reduce(_ state: inout State, _ action: Action, makeID: () -> UUID) -> [Command] {
        switch action {
        case .appeared:
            state.isVisible = true
            return reduce(&state, .refresh, makeID: makeID)
        case .disappeared:
            state.isVisible = false
            if state.readID != nil { state.activity = .idle }
            return [.cancelRead]
        case .refresh:
            guard !state.isWriting else { return [] }
            if let selected = state.selectedThreadID { return readConversation(&state, selected, append: false, makeID: makeID) }
            let id = makeID(); state.activity = .reading(id); state.issue = nil
            return [.cancelRead, .inbox(id)]
        case let .inboxLoaded(id, result):
            guard state.isVisible, state.readID == id else { return [] }
            state.activity = .idle
            switch result {
            case let .success(snapshot):
                if state.availability == .initial { state.availability = .ready }; state.threads = snapshot.page.threads; state.nextBefore = snapshot.page.nextBefore
                restorePending(&state, snapshot.pending)
                if let pending = state.pending, pending.kind == .reply { return readConversation(&state, pending.threadID, append: false, makeID: makeID) }
            case let .failure(failure): state.issue = .read(failure)
            }
            return []
        case let .inboxFailed(id, failure, pending):
            guard state.isVisible, state.readID == id else { return [] }
            state.activity = .idle; state.issue = .read(failure)
            restorePending(&state, pending)
            return []
        case .moreThreads:
            guard let cursor = state.nextBefore, state.activity == .idle else { return [] }
            let id = makeID(); state.activity = .reading(id); state.issue = nil
            return [.threads(id, cursor)]
        case let .threadsLoaded(id, result):
            guard state.isVisible, state.readID == id else { return [] }
            state.activity = .idle
            switch result {
            case let .success(page):
                state.issue = nil
                for thread in page.threads where !state.threads.contains(where: { $0.id == thread.id }) { state.threads.append(thread) }
                state.nextBefore = page.nextBefore
            case let .failure(error): state.issue = .read(error)
            }
            return []
        case .compose:
            guard state.isReady, state.pending == nil, state.activity == .idle else { return [] }
            state.route = .compose; state.conversation = nil; state.issue = nil; state.persistenceIssue = nil
            return []
        case let .open(id):
            guard !state.isWriting, state.pending == nil || state.pending?.threadID == id else { return [] }
            state.route = .conversation(id); state.conversation = nil
            return readConversation(&state, id, append: false, makeID: makeID)
        case .moreMessages:
            guard let id = state.selectedThreadID, state.conversation?.previousBefore != nil, state.activity == .idle else { return [] }
            return readConversation(&state, id, append: true, makeID: makeID)
        case let .conversationLoaded(requestID, threadID, append, result):
            guard state.isVisible, state.readID == requestID, state.selectedThreadID == threadID else { return [] }
            state.activity = .idle
            switch result {
            case let .success(page):
                if append, let existing = state.conversation {
                    let messages = (existing.messages + page.messages.filter { item in !existing.messages.contains(where: { $0.id == item.id }) }).sorted { $0.sequence < $1.sequence }
                    state.conversation = .init(thread: page.thread, messages: messages, nextAfter: page.nextAfter, previousBefore: page.previousBefore)
                } else { state.conversation = page }
                state.lastCommit = nil
                if state.availability == .initial { state.availability = .ready }
            case let .failure(error): state.issue = .read(error)
            }
            return []
        case .back:
            guard !state.isWriting, state.pending == nil else { return [] }
            state.route = .inbox; state.conversation = nil; state.issue = nil; state.persistenceIssue = nil
            return reduce(&state, .refresh, makeID: makeID)
        case let .draftChanged(value):
            guard !state.isWriting, state.pending == nil else { return [] }
            state.draft = value; state.issue = nil
            return []
        case .send:
            guard state.canSend else { return [] }
            let pending: InboxClient.PendingSend
            if let saved = state.pending { pending = saved }
            else {
                guard state.isComposing || state.selectedThreadID != nil else { return [] }
                pending = .init(kind: state.isComposing ? .newThread : .reply,
                    threadID: state.isComposing ? makeID() : state.selectedThreadID!, messageID: makeID(), body: state.draft)
            }
            let id = makeID(); state.pending = pending; state.activity = .writing(id); state.issue = nil; state.persistenceIssue = nil
            return [.cancelRead, .send(id, pending)]
        case let .sent(id, pending, result):
            guard state.activity == .writing(id), state.pending == pending else { return [] }
            state.activity = .idle
            switch result {
            case let .success(receipt):
                state.lastCommit = .init(threadID: pending.threadID, message: receipt.message)
                state.pending = receipt.persistenceIssue == nil ? nil : pending
                if receipt.persistenceIssue == nil {
                    if pending.kind == .newThread {
                        if state.newDraft.utf8.elementsEqual(pending.body.utf8) { state.newDraft = "" }
                    } else if state.replyDrafts[pending.threadID]?.utf8.elementsEqual(pending.body.utf8) == true { state.replyDrafts[pending.threadID] = nil }
                }
                state.route = .conversation(pending.threadID); if state.availability == .initial { state.availability = .ready }
                if let thread = receipt.thread {
                    state.conversation = .init(thread: thread, messages: [receipt.message])
                    state.threads.removeAll { $0.id == thread.id }; state.threads.insert(thread, at: 0)
                } else if let page = state.conversation {
                    var thread = page.thread; thread.updatedAt = receipt.message.createdAt
                    let messages = (page.messages.contains(where: { $0.id == receipt.message.id }) ? page.messages : page.messages + [receipt.message]).sorted { $0.sequence < $1.sequence }
                    state.conversation = .init(thread: thread, messages: messages, nextAfter: page.nextAfter, previousBefore: page.previousBefore)
                } else {
                    // A reconciled reply still needs its transcript after a cold/offline restoration.
                    state.persistenceIssue = receipt.persistenceIssue
                    return state.isVisible ? readConversation(&state, pending.threadID, append: false, makeID: makeID) : []
                }
                state.persistenceIssue = receipt.persistenceIssue
            case let .failure(error):
                state.issue = .send(error)
                if error.isDefinitive {
                    // A cold-restored pending body may have no unsent-draft backing yet.
                    if pending.kind == .newThread, state.newDraft.isEmpty { state.newDraft = pending.body }
                    else if pending.kind == .reply, state.replyDrafts[pending.threadID]?.isEmpty != false { state.replyDrafts[pending.threadID] = pending.body }
                    state.pending = nil
                }
                if error.serverCode == "installation_blocked" { state.availability = .blocked }
                if error.serverCode == "thread_closed", let page = state.conversation {
                    var thread = page.thread; thread.status = .closed
                    state.conversation = .init(thread: thread, messages: page.messages, nextAfter: page.nextAfter, previousBefore: page.previousBefore)
                }
                if error == .pendingSendConflict {
                    state.pending = nil; state.route = .inbox
                    return reduce(&state, .refresh, makeID: makeID)
                }
            }
            return []
        }
    }
    private static func restorePending(_ state: inout State, _ pending: InboxClient.PendingSend?) {
        state.pending = pending
        if let pending {
            state.route = pending.kind == .newThread ? .compose : .conversation(pending.threadID)
        }
    }
    private static func readConversation(_ state: inout State, _ id: UUID, append: Bool, makeID: () -> UUID) -> [Command] {
        let request = makeID(), before = append ? state.conversation?.previousBefore : nil
        state.activity = .reading(request); state.issue = nil
        return [.cancelRead, .conversation(request, id, before, append)]
    }
    /// Performs declared effects; consumer frameworks own tasks and cancellation.
    public static func perform(_ command: Command, client: Result<InboxClient, InboxClient.Failure>) async -> Action? {
        switch command {
        case .cancelRead: return nil
        case let .inbox(id):
            var pending: InboxClient.PendingSend?
            do {
                let service = try client.get(); pending = try await service.pendingSend()
                let page = try await service.list()
                guard !Task.isCancelled else { return nil }
                return .inboxLoaded(id, .success(.init(page: page, pending: pending)))
            } catch {
                guard !Task.isCancelled else { return nil }
                return .inboxFailed(id, .mapping(error), pending)
            }
        case let .threads(id, cursor):
            do { let page = try await client.get().list(before: cursor); return Task.isCancelled ? nil : .threadsLoaded(id, .success(page)) }
            catch { return Task.isCancelled ? nil : .threadsLoaded(id, .failure(.mapping(error))) }
        case let .conversation(request, id, before, append):
            do { let page = try await client.get().conversation(id, before: before); return Task.isCancelled ? nil : .conversationLoaded(request, id, append, .success(page)) }
            catch { return Task.isCancelled ? nil : .conversationLoaded(request, id, append, .failure(.mapping(error))) }
        case let .send(id, pending):
            do { return .sent(id, pending, .success(try await client.get().send(pending))) }
            catch { return .sent(id, pending, .failure(.mapping(error))) }
        }
    }
}
