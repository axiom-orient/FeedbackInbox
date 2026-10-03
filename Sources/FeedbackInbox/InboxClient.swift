import Foundation

/// Share one instance in the consumer. UI/state orchestration belongs to the app.
public actor InboxClient {
    public enum Phase: Equatable, Sendable { case idle, sending(PendingSend) }
    public private(set) var phase: Phase = .idle
    private struct RegistrationInput: Encodable { let id: UUID; let secret: String; let appID: String }
    private struct Registration: Decodable, Sendable { let id: UUID }
    private struct ServerError: Decodable { let error: String }
    private enum Enrollment { case needed, ready }
    private var enrollment: Enrollment = .needed
    private let configuration: Configuration
    private let io: ClientIO

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.io = .live(configuration: configuration)
    }
    init(configuration: Configuration, io: ClientIO) {
        self.configuration = configuration; self.io = io
    }

    public func pendingSend() throws -> PendingSend? { try io.storage.pending() }

    public func inbox() async throws -> Snapshot {
        let pending = try pendingSend()
        return Snapshot(page: try await list(), pending: pending)
    }
    public func list(before: String? = nil) async throws -> ThreadPage {
        try await request("threads", query: before.map { [URLQueryItem(name: "before", value: $0)] } ?? [])
    }
    public func conversation(_ id: UUID, before: Int? = nil) async throws -> Conversation {
        if let before, before <= 0 { throw Failure.invalidCursor }
        let page: Conversation = try await request("threads/\(id.uuidString.lowercased())", query: before.map {
            [URLQueryItem(name: "before", value: String($0))]
        } ?? [URLQueryItem(name: "latest", value: "1")])
        guard page.thread.id == id else { throw Failure.invalidResponse }
        return page
    }

    /// The caller injects stable IDs. An uncertain send must be retried with the same request.
    public func send(_ candidate: PendingSend) async throws -> Receipt {
        guard Policy.accepts(candidate.body) else { throw Failure.invalidMessage }
        guard case .idle = phase else { throw Failure.writeInProgress }
        phase = .sending(candidate)
        defer { phase = .idle }
        if let pending = try io.storage.pending(), !pending.matchesForRetry(candidate) { throw Failure.pendingSendConflict }
        let context: ClientContext
        if let supplied = candidate.clientContext { context = supplied }
        else { context = await io.context() }
        guard context.appID == configuration.appID, context.isValid else { throw Failure.invalidContext }
        // Admission is atomic across client instances; a saved snapshot always wins a retry.
        let submission = try io.storage.admit(candidate, context)
        phase = .sending(submission)
        let path: String, body: Data
        switch submission.kind {
        case .newThread:
            struct Input: Encodable { let id: UUID; let messageID: UUID; let body: String; let clientContext: ClientContext? }
            path = "threads"
            body = try JSONEncoder().encode(Input(id: submission.threadID, messageID: submission.messageID, body: submission.body, clientContext: submission.clientContext))
        case .reply:
            struct Input: Encodable { let id: UUID; let body: String; let clientContext: ClientContext? }
            path = "threads/\(submission.threadID.uuidString.lowercased())/messages"
            body = try JSONEncoder().encode(Input(id: submission.messageID, body: submission.body, clientContext: submission.clientContext))
        }
        do {
            guard body.count <= Policy.maximumPayloadBytes else { throw Failure.payloadTooLarge }
            var receipt: Receipt = try await request(path, body: body)
            guard receipt.message.id == submission.messageID, receipt.message.sender == .user,
                  receipt.message.body.utf8.elementsEqual(submission.body.utf8), receipt.message.clientContext == submission.clientContext,
                  receipt.message.sequence > 0,
                  submission.kind != .newThread || receipt.thread?.id == submission.threadID else { throw Failure.invalidResponse }
            // Once committed, cancellation or local cleanup failure must not erase that receipt.
            do { try io.storage.clear(submission) }
            catch { receipt.persistenceIssue = Failure.mapping(error) }
            return receipt
        } catch {
            let failure = Failure.mapping(error)
            if failure.isDefinitive {
                do { try io.storage.clear(submission) }
                catch { throw Failure.cleanupFailed(rejection: failure.serverCode, status: Failure.storageStatus(error)) }
            }
            throw failure
        }
    }

    private func request<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        do {
            try Task.checkCancellation()
            let credential = try io.storage.credential()
            if case .needed = enrollment {
                let registration: Registration = try await perform(configuration.serverURL.appendingPathComponent("installations"),
                    body: JSONEncoder().encode(RegistrationInput(id: credential.id, secret: credential.secret, appID: configuration.appID)), authorization: nil)
                guard registration.id == credential.id else { throw Failure.invalidResponse }
                enrollment = .ready
            }
            guard var components = URLComponents(url: configuration.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw Failure.invalidConfiguration }
            components.queryItems = query.isEmpty ? nil : query
            guard let url = components.url else { throw Failure.invalidConfiguration }
            return try await perform(url, body: body, authorization: "Bearer \(credential.id.uuidString.lowercased()):\(credential.secret)")
        } catch { throw Failure.mapping(error) }
    }
    private func perform<T: Decodable & Sendable>(_ url: URL, body: Data?, authorization: String?) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let response = try await io.exchange(request)
        guard (200..<300).contains(response.status) else {
            throw Failure.server(status: response.status, code: (try? JSONDecoder().decode(ServerError.self, from: response.data))?.error)
        }
        do { return try JSONDecoder().decode(T.self, from: response.data) }
        catch { throw Failure.invalidResponse }
    }
}
