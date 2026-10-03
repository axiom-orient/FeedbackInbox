import Foundation
import SwiftUI

/// Stateless rendering for apps with an existing reducer/store. No second observable owner.
@MainActor public struct InboxScreen: View {
    public let state: InboxFlow.State
    private let style: InboxStyle
    private let locale: Locale
    private let send: (InboxFlow.Action) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isWriting: Bool
    @State private var transferExpanded = false
    @State private var earlierAnchor: UUID?
    public init(state: InboxFlow.State, style: InboxStyle = .init(), locale: Locale = .current,
                send: @escaping (InboxFlow.Action) -> Void) {
        self.state=state; self.style=style; self.locale=locale; self.send=send
    }
    private var copy: InboxCopy { InboxCopy(locale: locale) }
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: style.spacing) {
                    if let failure = state.failure {
                        Text(state.lastCommit != nil && state.lastCommit?.threadID == state.selectedThreadID && state.issue == .read(failure) ? copy("savedReadFailed") : copy.failure(failure)).foregroundStyle(style.errorInk).accessibilityIdentifier("privateFeedback.error")
                        if state.pending == nil { Button(copy("retry")) { send(.refresh) }.accessibilityIdentifier("privateFeedback.retry") }
                    } else if state.availability == .blocked { Text(copy("blocked")).foregroundStyle(style.errorInk) }
                    if state.persistenceIssue != nil { Text(copy("cleanup")).font(style.captionFont).foregroundStyle(style.secondaryInk) }
                    if state.readID != nil { ProgressView(copy("loading")).accessibilityIdentifier("privateFeedback.loading") }
                    if let page = state.conversation { conversation(page) }
                    else if let commit = state.lastCommit, commit.threadID == state.selectedThreadID { messageCard(commit.message) }
                    else if state.route == .inbox { inbox }
                }.padding(style.inset)
            }
            .defaultScrollAnchor(state.route == .inbox || state.isComposing ? .top : .bottom)
            .modifier(ShortConversationAlignment())
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: state.conversation?.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: state.conversation?.messages.first?.id) { _, _ in
                if let anchor = earlierAnchor, state.readID == nil { proxy.scrollTo(anchor, anchor: .top); earlierAnchor = nil }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.route != .inbox {
                contextActions.padding(.horizontal, style.inset).padding(.vertical, style.controlSpacing).background(style.background)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.isComposing || state.conversation?.thread.status == .open || state.pending != nil || (state.selectedThreadID != nil && !state.draft.isEmpty) {
                composer.padding(style.inset).background(style.composerBackground)
            }
        }
        .background(style.background).foregroundStyle(style.ink).font(style.controlFont)
        .navigationTitle(copy(state.isComposing ? "composeTitle" : state.route == .inbox ? "title" : "threadTitle"))
        .modifier(InboxInlineTitle())
        .task { send(.appeared) }.onDisappear { send(.disappeared) }
        .onChange(of: scenePhase) { _, phase in if phase == .active, state.isVisible { send(.refresh) } }
        .onChange(of: state.route) { _, _ in transferExpanded = false; earlierAnchor = nil }
        .refreshable { send(.refresh) }
        .environment(\.locale, locale)
    }
    private var contextActions: some View {
        HStack(spacing: style.spacing) {
            Button { isWriting = false; send(.back) } label: {
                Text(copy("inbox")).frame(minHeight: style.touchSize)
            }.buttonStyle(.bordered).disabled(state.pending != nil || state.isWriting)
                .accessibilityIdentifier("privateFeedback.inbox")
            Spacer()
            if !state.isComposing { refreshButton }
        }.font(style.controlFont)
    }
    private var refreshButton: some View {
        Button { send(.refresh) } label: {
            Label { Text(copy("refreshAction")) } icon: { Image(systemName: "arrow.clockwise").font(style.navigationFont) }
                .frame(minHeight: style.touchSize)
        }.buttonStyle(.bordered).font(style.controlFont)
            .accessibilityLabel(copy("refresh")).accessibilityHint(copy("refreshHint"))
            .accessibilityIdentifier("privateFeedback.refresh").disabled(state.activity != .idle)
    }
    private var inbox: some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            HStack(spacing: style.spacing) {
                Button { send(.compose) } label: {
                    Label(copy("new"), systemImage: "square.and.pencil").frame(maxWidth: .infinity, minHeight: style.touchSize)
                }.modifier(InboxPrimaryAction(style: style))
                    .disabled(!state.isReady || state.pending != nil || state.activity != .idle).accessibilityIdentifier("privateFeedback.new")
                refreshButton
            }
            Text(copy("intro")).font(style.captionFont).foregroundStyle(style.secondaryInk)
            if state.isReady && state.threads.isEmpty { Text(copy("empty")).foregroundStyle(style.secondaryInk).accessibilityIdentifier("privateFeedback.empty") }
            ForEach(state.threads) { thread in
                Button { send(.open(thread.id)) } label: {
                    VStack(alignment: .leading, spacing: style.controlSpacing) {
                        Text(thread.preview).lineLimit(2).multilineTextAlignment(.leading)
                        if let preview = thread.lastPreview, preview != thread.preview {
                            Text(preview).lineLimit(2).font(style.captionFont).foregroundStyle(style.secondaryInk).multilineTextAlignment(.leading)
                        }
                        HStack {
                            Text(status(thread)); Spacer(); Text(Date(timeIntervalSince1970: thread.updatedAt), style: .date)
                        }.font(style.captionFont).foregroundStyle(style.secondaryInk)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(style.inset)
                        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: style.radius))
                }.buttonStyle(.plain).accessibilityLabel("\(thread.preview), \(status(thread)), \(thread.lastPreview ?? "")")
                    .accessibilityIdentifier("privateFeedback.thread.\(thread.id.uuidString.lowercased())")
            }
            if state.nextBefore != nil { Button(copy("moreThreads")) { send(.moreThreads) }.disabled(state.activity != .idle) }
            DisclosureGroup(copy("help")) { Text(copy("helpBody")) }.font(style.captionFont).foregroundStyle(style.secondaryInk)
        }
    }
    private func status(_ thread: InboxClient.Thread) -> String { copy(thread.status == .closed ? "closed" : thread.lastSender == .operator ? "answered" : "open") }
    private func conversation(_ page: InboxClient.Conversation) -> some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            if page.previousBefore != nil {
                Button(copy("older")) { earlierAnchor = page.messages.first?.id; send(.moreMessages) }
                    .disabled(state.activity != .idle).accessibilityIdentifier("privateFeedback.older")
            }
            ForEach(page.messages) { message in messageCard(message) }
            if page.thread.status == .closed && state.pending == nil { Text(copy("closedBody")).foregroundStyle(style.secondaryInk) }
        }
    }
    private func messageCard(_ message: InboxClient.Message) -> some View {
        VStack(alignment: .leading, spacing: style.controlSpacing) {
            Text(copy(message.sender == .user ? "me" : "developer")).font(style.titleFont)
            Text(message.body).font(style.bodyFont).textSelection(.enabled)
            Text(Date(timeIntervalSince1970: message.createdAt), format: .dateTime.month().day().hour().minute())
                .font(style.captionFont).foregroundStyle(style.secondaryInk)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(style.inset)
            .background(style.cardBackground, in: RoundedRectangle(cornerRadius: style.radius))
            .accessibilityElement(children: .combine).accessibilityIdentifier("privateFeedback.message.\(message.id.uuidString.lowercased())").id(message.id)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: style.controlSpacing) {
            DisclosureGroup(copy("transfer"), isExpanded: $transferExpanded) { Text(copy("transferBody")) }
                .font(style.captionFont).foregroundStyle(style.secondaryInk).accessibilityIdentifier("privateFeedback.transferInfo")
            TextField(copy(state.isComposing ? "body" : "reply"), text: Binding(get: { state.draft }, set: { send(.draftChanged($0)) }), axis: .vertical)
                .lineLimit(2...6).font(style.bodyFont).focused($isWriting).disabled(state.pending != nil || state.isWriting)
                .padding(style.spacing).background(style.cardBackground, in: RoundedRectangle(cornerRadius: style.radius))
                .accessibilityIdentifier("privateFeedback.body")
            if state.draft.unicodeScalars.count > InboxClient.Policy.maximumCharacters { Text(copy("limit")).font(style.captionFont).foregroundStyle(style.errorInk) }
            if state.pending != nil { Text(copy("pending")).font(style.captionFont).foregroundStyle(style.secondaryInk) }
            HStack {
                if isWriting { Button(copy("done")) { isWriting = false }.buttonStyle(.bordered).accessibilityIdentifier("privateFeedback.inputDone") }
                Spacer()
                if state.isWriting { ProgressView(copy("sending")) }
                Button(copy(state.pending == nil ? "send" : "confirm")) { isWriting = false; send(.send) }
                    .modifier(InboxPrimaryAction(style: style)).disabled(!state.canSend).accessibilityIdentifier("privateFeedback.send")
            }
        }
    }
}
private struct InboxPrimaryAction: ViewModifier {
    let style: InboxStyle
    func body(content: Content) -> some View { content.buttonStyle(.borderedProminent).controlSize(.large).tint(style.accent).foregroundStyle(style.onAccent) }
}
private struct InboxInlineTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}
private struct ShortConversationAlignment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) { content.defaultScrollAnchor(.top, for: .alignment) } else { content }
    }
}
struct InboxCopy {
    let locale: Locale
    func callAsFunction(_ key: String) -> String {
        let language = locale.language.languageCode?.identifier == "ko" ? "ko" : "en"
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
    func failure(_ error: InboxClient.Failure) -> String {
        switch error {
        case .invalidMessage, .payloadTooLarge: return self("invalidMessage")
        case .invalidConfiguration, .invalidContext: return self("config")
        case .pendingSendConflict, .writeInProgress: return self("conflict")
        case .storage, .invalidStoredState: return self("storage")
        case .cleanupFailed: return self("cleanupRejected")
        case let .server(_, code):
            return self(["daily_thread_limit":"daily","write_burst":"burst","registration_burst":"burst","thread_closed":"closedBody",
                "installation_blocked":"blocked","unauthorized":"unauthorized","invalid_message":"invalidMessage","payload_too_large":"invalidMessage",
                "invalid_client_context":"context","app_not_supported":"config","app_context_mismatch":"config","app_not_configured":"config","id_conflict":"idConflict"][code ?? ""] ?? "unknown")
        default: return self("unknown")
        }
    }
}
