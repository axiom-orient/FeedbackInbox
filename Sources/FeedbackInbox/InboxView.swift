import Foundation
import Observation
import SwiftUI

/// Complete inbox with a NavigationStack by default; use embedded navigation inside the consumer's shell.
@MainActor public struct InboxView: View {
    public enum Navigation: Sendable { case standalone, embedded }
    @State private var session: InboxSession
    private let style: InboxStyle
    private let locale: Locale
    private let navigation: Navigation
    public init(serverURL: URL, style: InboxStyle = .init(), locale: Locale = .current, navigation: Navigation = .standalone) {
        let client: Result<InboxClient, InboxClient.Failure>
        do {
            guard let appID = Bundle.main.bundleIdentifier else { throw InboxClient.Failure.invalidConfiguration }
            client = .success(InboxClient(configuration: try .init(serverURL: serverURL, appID: appID)))
        } catch { client = .failure(.mapping(error)) }
        self._session = State(initialValue: InboxSession(client: client)); self.style = style; self.locale = locale; self.navigation = navigation
    }
    public init(configuration: InboxClient.Configuration, style: InboxStyle = .init(), locale: Locale = .current, navigation: Navigation = .standalone) {
        self._session = State(initialValue: InboxSession(client: .success(InboxClient(configuration: configuration))))
        self.style = style; self.locale = locale; self.navigation = navigation
    }
    public var body: some View {
        if navigation == .standalone {
            NavigationStack { InboxScreen(state: session.state, style: style, locale: locale, send: session.send) }
        } else { InboxScreen(state: session.state, style: style, locale: locale, send: session.send) }
    }
}

@MainActor @Observable private final class InboxSession {
    var state = InboxFlow.State()
    private let client: Result<InboxClient, InboxClient.Failure>
    private var read: (id: UUID, task: Task<Void, Never>)?
    private var write: Task<Void, Never>?
    init(client: Result<InboxClient, InboxClient.Failure>) { self.client = client }
    func send(_ action: InboxFlow.Action) {
        let commands = InboxFlow.reduce(&state, action, makeID: { UUID() })
        for command in commands {
            if command == .cancelRead { read?.task.cancel(); read = nil; continue }
            if let id = command.readID {
                let task = Task { [self] in
                    if let response = await InboxFlow.perform(command, client: client) { send(response) }
                    if read?.id == id { read = nil }
                }
                read = (id, task)
            } else {
                write = Task { [self] in
                    if let response = await InboxFlow.perform(command, client: client) { send(response) }
                    write = nil
                }
            }
        }
    }
}
