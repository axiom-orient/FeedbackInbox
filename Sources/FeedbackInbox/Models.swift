import Foundation

extension InboxClient {
    public struct Thread: Codable, Equatable, Identifiable, Sendable {
        public enum Status: String, Codable, Sendable { case open, closed }
        public let id: UUID
        public var status: Status
        public let createdAt: TimeInterval
        public var updatedAt: TimeInterval
        public var preview: String
        public var lastSender: Message.Sender?
        public var lastPreview: String?
        public init(id: UUID, status: Status, createdAt: TimeInterval, updatedAt: TimeInterval, preview: String,
                    lastSender: Message.Sender? = nil, lastPreview: String? = nil) {
            self.id=id; self.status=status; self.createdAt=createdAt; self.updatedAt=updatedAt; self.preview=preview
            self.lastSender=lastSender; self.lastPreview=lastPreview
        }
    }
    public struct ClientContext: Codable, Equatable, Sendable {
        public var schemaVersion = 1
        public let appName: String?
        public let appID: String?
        public let appVersion: String?
        public let appBuild: String?
        public let osName: String?
        public let osVersion: String?
        public let deviceModel: String?
        public let language: String?
        public init(appName: String? = nil, appID: String? = nil, appVersion: String? = nil, appBuild: String? = nil,
                    osName: String? = nil, osVersion: String? = nil, deviceModel: String? = nil, language: String? = nil) {
            self.appName=appName; self.appID=appID; self.appVersion=appVersion; self.appBuild=appBuild
            self.osName=osName; self.osVersion=osVersion; self.deviceModel=deviceModel; self.language=language
        }
        var isValid: Bool {
            let fields: [(String?, Int)] = [(appName,128),(appID,128),(appVersion,64),(appBuild,64),(osName,32),(osVersion,64),(deviceModel,128),(language,64)]
            guard schemaVersion == 1, fields.allSatisfy({ value, limit in
                guard let value else { return true }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= limit
                    && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            }), let encoded = try? JSONEncoder().encode(self) else { return false }
            return encoded.count <= 2_048
        }
    }
    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public enum Sender: String, Codable, Sendable { case user, `operator` }
        public let id: UUID
        public let sequence: Int
        public let sender: Sender
        public let body: String
        public let createdAt: TimeInterval
        public var clientContext: ClientContext?
        public init(id: UUID, sequence: Int, sender: Sender, body: String, createdAt: TimeInterval, clientContext: ClientContext? = nil) {
            self.id=id; self.sequence=sequence; self.sender=sender; self.body=body; self.createdAt=createdAt; self.clientContext=clientContext
        }
    }
    public struct ThreadPage: Codable, Equatable, Sendable {
        public let threads: [Thread]
        public let nextBefore: String?
        public init(threads: [Thread], nextBefore: String?) { self.threads=threads; self.nextBefore=nextBefore }
    }
    public struct Conversation: Codable, Equatable, Sendable {
        public let thread: Thread
        public let messages: [Message]
        public let nextAfter: Int?
        public var previousBefore: Int?
        public init(thread: Thread, messages: [Message], nextAfter: Int? = nil, previousBefore: Int? = nil) {
            self.thread=thread; self.messages=messages; self.nextAfter=nextAfter; self.previousBefore=previousBefore
        }
    }
    public struct PendingSend: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case newThread, reply }
        public let kind: Kind
        public let threadID: UUID
        public let messageID: UUID
        public let body: String
        public var clientContext: ClientContext?
        public init(kind: Kind, threadID: UUID, messageID: UUID, body: String, clientContext: ClientContext? = nil) {
            self.kind=kind; self.threadID=threadID; self.messageID=messageID; self.body=body; self.clientContext=clientContext
        }
        public func matchesForRetry(_ candidate: Self) -> Bool {
            kind == candidate.kind && threadID == candidate.threadID && messageID == candidate.messageID && body.utf8.elementsEqual(candidate.body.utf8)
                && (candidate.clientContext == nil || clientContext == candidate.clientContext)
        }
    }
    public struct Receipt: Decodable, Equatable, Sendable {
        public let thread: Thread?
        public let message: Message
        public internal(set) var persistenceIssue: Failure? = nil
        enum CodingKeys: String, CodingKey { case thread, message }
    }
    public struct Snapshot: Equatable, Sendable {
        public let page: ThreadPage
        public let pending: PendingSend?
        public init(page: ThreadPage, pending: PendingSend?) { self.page=page; self.pending=pending }
    }
}
