import Foundation

extension InboxClient {
    public struct Configuration: Equatable, Sendable {
        public let serverURL: URL
        public let appID: String
        public init(serverURL: URL, appID: String) throws {
            let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
            guard serverURL.scheme == "https", serverURL.host?.isEmpty == false,
                  serverURL.user == nil, serverURL.password == nil, serverURL.query == nil, serverURL.fragment == nil,
                  serverURL.path.isEmpty || serverURL.path == "/",
                  (3...128).contains(appID.utf8.count), let first = appID.utf8.first, alphanumeric(first),
                  appID.utf8.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 }) else { throw Failure.invalidConfiguration }
            self.serverURL = serverURL; self.appID = appID
        }
        var keychainService: String { appID + ".feedback" }
    }
    public enum Policy {
        public static let maximumCharacters = 5_000
        public static let maximumPayloadBytes = 24_000
        public static func accepts(_ body: String) -> Bool {
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.unicodeScalars.count <= maximumCharacters
        }
    }
    public enum Failure: Swift.Error, Equatable, Sendable {
        case invalidConfiguration, invalidMessage, payloadTooLarge, invalidContext, invalidCursor
        case pendingSendConflict, writeInProgress, invalidStoredState, invalidResponse, cancelled
        case storage(status: Int32)
        case transport(code: Int)
        case server(status: Int, code: String?)
        case cleanupFailed(rejection: String?, status: Int32?)

        /// True only for local admission failures or a recognized, correctly-statused server rejection.
        public var isDefinitive: Bool {
            switch self {
            case .invalidConfiguration, .invalidMessage, .payloadTooLarge, .invalidContext, .invalidCursor: return true
            case let .server(status, code):
                let statuses = ["daily_thread_limit":429,"write_burst":429,"registration_burst":429,
                    "thread_closed":409,"installation_blocked":403,"invalid_message":400,"payload_too_large":413,
                    "invalid_client_context":400,"app_not_supported":400,"app_context_mismatch":400]
                return code.flatMap { statuses[$0] } == status
            default: return false
            }
        }
        public var serverCode: String? { if case let .server(_, code) = self { return code }; return nil }
        static func mapping(_ error: any Swift.Error) -> Self {
            if let failure = error as? Self { return failure }
            if error is CancellationError { return .cancelled }
            if let error = error as? URLError { return error.code == .cancelled ? .cancelled : .transport(code: error.code.rawValue) }
            return .invalidResponse
        }
        static func storageStatus(_ error: any Swift.Error) -> Int32? {
            if case let .storage(status) = mapping(error) { return status }; return nil
        }
    }
}
