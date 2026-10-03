import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct Credential: Codable, Equatable, Sendable {
    let id: UUID
    let secret: String
}
struct ClientStorage: Sendable {
    var credential: @Sendable () throws -> Credential
    var pending: @Sendable () throws -> InboxClient.PendingSend?
    var admit: @Sendable (InboxClient.PendingSend, InboxClient.ClientContext) throws -> InboxClient.PendingSend
    var clear: @Sendable (InboxClient.PendingSend) throws -> Void
}
struct HTTPResult: Sendable { let data: Data; let status: Int }
struct ClientIO: Sendable {
    let storage: ClientStorage
    let context: @Sendable () async -> InboxClient.ClientContext
    let exchange: @Sendable (URLRequest) async throws -> HTTPResult
    static func live(configuration: InboxClient.Configuration) -> Self {
        let keychain = KeychainStorage(service: configuration.keychainService)
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 30; options.timeoutIntervalForResource = 45
        let session = URLSession(configuration: options)
        return Self(storage: keychain.clientStorage,
            context: { await InboxClient.ClientContext.capture() },
            exchange: { request in
                // Enrollment carries the installation secret; never forward it to a redirect target.
                let (data, response) = try await session.data(for: request, delegate: InboxRedirectPolicy())
                guard let response = response as? HTTPURLResponse else { throw InboxClient.Failure.invalidResponse }
                return HTTPResult(data: data, status: response.statusCode)
            })
    }
}
private final class InboxRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
extension InboxClient.ClientContext {
    /// A single send-time snapshot; no unique device identifiers or journal data.
    @MainActor public static func capture() -> Self {
        let bundle = Bundle.main
        func info(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
            return value
        }
        #if canImport(UIKit)
        let device = UIDevice.current
        let osName = device.systemName, osVersion = device.systemVersion, deviceModel = device.model
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osName = "macOS", osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", deviceModel = "Mac"
        #endif
        return Self(appName: info("CFBundleDisplayName") ?? info("CFBundleName"), appID: bundle.bundleIdentifier,
            appVersion: info("CFBundleShortVersionString"), appBuild: info("CFBundleVersion"),
            osName: osName, osVersion: osVersion, deviceModel: deviceModel, language: Locale.preferredLanguages.first)
    }
}
