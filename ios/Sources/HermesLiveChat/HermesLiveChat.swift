import Foundation

public final class HermesLiveChat {
    public static let shared = HermesLiveChat()

    private var config: HermesLiveChatConfig?
    private var api: ApiClient?
    private var realtime: RealtimeClient?
    private var stored: StoredSession?
    private var realtimeIdleTask: Task<Void, Never>?
    private var realtimeUrl: URL?
    private var realtimeToken: String?
    private var realtimeState: LiveChatConnectionState = .idle
    private var seen = Set<String>()
    private let store = SessionStore()
    private var continuations: [UUID: AsyncStream<HermesLiveChatEvent>.Continuation] = [:]

    public private(set) var currentConversationId: String?

    private init() {}

    public func configure(_ config: HermesLiveChatConfig) {
        disconnect()
        self.config = config
        self.api = ApiClient(config: config)
        self.realtime = RealtimeClient(
            emit: { [weak self] event in self?.emitRealtimeEvent(event) },
            onPublication: { [weak self] json in self?.handlePublication(json) }
        )
        self.stored = nil
        self.currentConversationId = nil
        self.seen.removeAll()
    }

    public func events() -> AsyncStream<HermesLiveChatEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    public func prefetchWelcome(locale: String? = nil) async throws -> String {
        let json = try await requireApi().publicConfig(locale: locale)
        if let welcome = json["welcome"] as? String { return welcome }
        let config = json["config"] as? [String: Any]
        return config?["welcome"] as? String ?? ""
    }

    @discardableResult
    public func startSession(_ identity: VisitorIdentity) async throws -> VisitorSession {
        let cfg = try requireConfig()
        let cached = stored ?? store.load(appKey: cfg.appKey)
        currentConversationId = currentConversationId ?? cached?.lastConversationId
        if let cached, !isExpired(cached.tokenExp) {
            stored = cached
            connectRealtime(url: cached.realtimeUrl ?? cfg.realtimeUrl, token: cached.token)
            return cached.toVisitorSession(defaultRealtimeUrl: cfg.realtimeUrl)
        }

        let next = try await renewSession(identity: identity, oldToken: cached?.token, fallbackRealtimeUrl: nil)
        await refreshCurrentConversation(token: next.token)
        connectRealtime(url: next.realtimeUrl ?? cfg.realtimeUrl, token: next.token)
        return next.toVisitorSession(defaultRealtimeUrl: cfg.realtimeUrl)
    }

    public func sendText(_ text: String, conversationId: String? = nil) async throws -> Message {
        try await sendTextResult(text, conversationId: conversationId).message
    }

    public func sendTextMessages(_ text: String, conversationId: String? = nil) async throws -> [Message] {
        try await sendTextResult(text, conversationId: conversationId).messages
    }

    private func sendTextResult(_ text: String, conversationId: String? = nil) async throws -> SendMessageResult {
        let token = try await validToken()
        let clientMsgId = newClientMsgId()
        try ensureRealtimeConnected(token: token)
        let result = try await retryOnConversationClosed(conversationId) { [api = try requireApi()] convId in
            try await api.sendText(token: token, conversationId: convId, text: text, clientMsgId: clientMsgId)
        }
        return handleSendResult(result)
    }

    public func sendImage(
        data: Data,
        mimeType: String,
        filename: String? = nil,
        conversationId: String? = nil
    ) async throws -> Message {
        try await sendImageResult(data: data, mimeType: mimeType, filename: filename, conversationId: conversationId).message
    }

    public func sendImageMessages(
        data: Data,
        mimeType: String,
        filename: String? = nil,
        conversationId: String? = nil
    ) async throws -> [Message] {
        try await sendImageResult(data: data, mimeType: mimeType, filename: filename, conversationId: conversationId).messages
    }

    private func sendImageResult(
        data: Data,
        mimeType: String,
        filename: String? = nil,
        conversationId: String? = nil
    ) async throws -> SendMessageResult {
        let token = try await validToken()
        let api = try requireApi()
        let presign = try await api.presign(
            token: token,
            filename: filename ?? defaultImageFilename(mimeType: mimeType),
            mimeType: mimeType,
            size: data.count
        )
        guard
            let uploadURLString = presign["upload_url"] as? String,
            let uploadURL = URL(string: uploadURLString),
            let downloadURL = presign["download_url"] as? String,
            let key = presign["key"] as? String
        else {
            throw HermesLiveChatException(error: .badRequest, code: nil, message: "invalid attachment presign response", status: nil)
        }
        try await api.uploadPresigned(
            url: uploadURL,
            method: presign["method"] as? String ?? "PUT",
            headers: presign["headers"] as? [String: String] ?? [:],
            data: data
        )
        let clientMsgId = newClientMsgId()
        try ensureRealtimeConnected(token: token)
        let result = try await retryOnConversationClosed(conversationId) { convId in
            try await api.sendImage(
                token: token,
                conversationId: convId,
                key: key,
                url: downloadURL,
                mimeType: mimeType,
                size: data.count,
                clientMsgId: clientMsgId
            )
        }
        return handleSendResult(result)
    }

    // retryOnConversationClosed runs `send` once with the caller-supplied (or
    // remembered) conversation id; if the backend reports `.conversationClosed`
    // and the caller did NOT pin a specific conversation, the stale pointer is
    // dropped and the request retried with conversationId=nil so the server
    // allocates a fresh one.
    private func retryOnConversationClosed<R>(
        _ explicitConversationId: String?,
        _ send: (_ conversationId: String?) async throws -> R
    ) async throws -> R {
        let implicit = explicitConversationId == nil
        let convId = explicitConversationId ?? currentConversationId
        do {
            return try await send(convId)
        } catch let error as HermesLiveChatException where implicit && error.error == .conversationClosed {
            forgetCurrentConversation(convId)
            return try await send(nil)
        }
    }

    public func history(conversationId: String, afterId: String? = nil, limit: Int = 50) async throws -> [Message] {
        let messages = try await requireApi().history(
            token: try await validToken(),
            conversationId: conversationId,
            afterId: afterId,
            limit: limit
        )
        rememberConversation(conversationId)
        return messages.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            let leftRank = messageSortRank($0)
            let rightRank = messageSortRank($1)
            if leftRank != rightRank { return leftRank < rightRank }
            return $0.uuid < $1.uuid
        }
    }

    private func messageSortRank(_ message: Message) -> Int {
        if message.contentType == "welcome" { return 0 }
        if message.contentType == "close" { return 2 }
        return 1
    }

    public func markRead(conversationId: String, messageId: String) async throws {
        try await requireApi().markRead(token: try await validToken(), messageId: messageId)
        rememberConversation(conversationId)
    }

    private func handleSendResult(_ result: SendMessageResult) -> SendMessageResult {
        if let conversation = result.conversation {
            rememberConversation(conversation.uuid)
        }
        for message in result.messages {
            _ = rememberSeen(message.uuid)
            _ = rememberSeen(message.clientMsgId)
            if message.uuid == result.message.uuid || message.clientMsgId == result.message.clientMsgId {
                continue
            }
            if let conversation = result.conversation {
                emit(.messageReceived(message, conversation))
            }
        }
        rememberConversation(result.message.conversationId)
        _ = rememberSeen(result.message.uuid)
        _ = rememberSeen(result.message.clientMsgId)
        touchRealtimeActivity()
        return result
    }

    public func disconnect() {
        realtimeIdleTask?.cancel()
        realtimeIdleTask = nil
        realtimeUrl = nil
        realtimeToken = nil
        realtimeState = .idle
        realtime?.disconnect()
    }

    public func destroy() {
        disconnect()
        stored = nil
        currentConversationId = nil
        seen.removeAll()
    }

    private func handlePublication(_ json: [String: Any]) {
        touchRealtimeActivity()
        if let eventId = json["event_id"] as? String, !rememberSeen(eventId) {
            return
        }
        switch json["type"] as? String {
        case "livechat.message.created":
            guard
                let m = json["message"] as? [String: Any],
                let c = json["conversation"] as? [String: Any]
            else { return }
            let message = Message.from(m)
            if !rememberSeen(message.uuid) || !rememberSeen(message.clientMsgId) { return }
            let conversation = Conversation.from(c)
            rememberPublicationConversation(conversation)
            emit(.messageReceived(message, conversation))
        case "livechat.conversation.updated":
            guard let c = json["conversation"] as? [String: Any] else { return }
            let conversation = Conversation.from(c)
            rememberPublicationConversation(conversation)
            emit(.conversationUpdated(conversation))
        case "livechat.message.read":
            guard
                let c = json["conversation"] as? [String: Any],
                let m = json["message"] as? [String: Any]
            else { return }
            emit(.messageRead(
                conversationId: c["uuid"] as? String ?? "",
                messageId: m["uuid"] as? String ?? "",
                readAt: m["read_at"] as? Int ?? 0
            ))
        default:
            break
        }
    }

    private func validToken() async throws -> String {
        let cfg = try requireConfig()
        let session = stored ?? store.load(appKey: cfg.appKey)
        guard let session else {
            throw HermesLiveChatException(error: .notConfigured, code: nil, message: "startSession() must be called first", status: nil)
        }
        stored = session
        if !isExpired(session.tokenExp) { return session.token }

        let next = try await renewSession(
            identity: VisitorIdentity(),
            oldToken: session.token,
            fallbackRealtimeUrl: session.realtimeUrl
        )
        await refreshCurrentConversation(token: next.token)
        connectRealtime(url: next.realtimeUrl ?? cfg.realtimeUrl, token: next.token)
        return next.token
    }

    // renewSession hits /init (passing `oldToken` for renewal semantics),
    // persists the response, and returns the new StoredSession. Both
    // startSession and validToken share this — formerly each had its own copy
    // of the JSON-extract + store.save block.
    private func renewSession(
        identity: VisitorIdentity,
        oldToken: String?,
        fallbackRealtimeUrl: URL?
    ) async throws -> StoredSession {
        let cfg = try requireConfig()
        let json = try await requireApi().initSession(identity: identity, oldVisitorToken: oldToken)
        let realtimeUrl = ((json["realtime"] as? [String: Any])?["url"] as? String)
            .flatMap(URL.init(string:)) ?? fallbackRealtimeUrl ?? cfg.realtimeUrl
        let fallback = stored
        let next = StoredSession(
            appKey: cfg.appKey,
            visitorId: json["visitor_id"] as? String ?? fallback?.visitorId ?? "",
            contactId: json["contact_id"] as? Int ?? fallback?.contactId ?? 0,
            token: json["token"] as? String ?? fallback?.token ?? "",
            tokenExp: json["token_exp"] as? Int ?? fallback?.tokenExp ?? 0,
            realtimeUrl: realtimeUrl,
            lastConversationId: currentConversationId ?? fallback?.lastConversationId
        )
        stored = next
        store.save(next)
        return next
    }

    private func refreshCurrentConversation(token: String) async {
        guard let conversations = try? await requireApi().listConversations(token: token) else { return }
        if let active = conversations.first(where: { $0.status != "closed" }) {
            rememberConversation(active.uuid)
        }
    }

    private func ensureRealtimeConnected(token: String) throws {
        let cfg = try requireConfig()
        guard let session = stored else { return }
        connectRealtime(url: session.realtimeUrl ?? cfg.realtimeUrl, token: token)
    }

    private func connectRealtime(url: URL, token: String) {
        if realtimeUrl == url && realtimeToken == token && realtimeCanReuse {
            touchRealtimeActivity()
            return
        }
        realtime?.connect(url: url, token: token)
        realtimeUrl = url
        realtimeToken = token
        realtimeState = .connecting
        touchRealtimeActivity()
    }

    private var realtimeCanReuse: Bool {
        switch realtimeState {
        case .connecting, .connected:
            return true
        case .idle, .disconnected:
            return false
        }
    }

    private func touchRealtimeActivity() {
        realtimeIdleTask?.cancel()
        guard let delay = config?.realtimeIdleDisconnectDelay, delay > 0 else { return }
        let nanoseconds = UInt64(delay * 1_000_000_000)
        realtimeIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.disconnect()
        }
    }

    private func emitRealtimeEvent(_ event: HermesLiveChatEvent) {
        if case let .connectionStateChanged(state) = event {
            realtimeState = state
            if case .idle = state {
                realtimeUrl = nil
                realtimeToken = nil
            }
        }
        emit(event)
    }

    private func rememberPublicationConversation(_ conversation: Conversation) {
        if conversation.status == "closed" {
            forgetCurrentConversation(conversation.uuid)
            return
        }
        rememberConversation(conversation.uuid)
    }

    private func rememberConversation(_ id: String) {
        guard !id.isEmpty else { return }
        currentConversationId = id
        guard var session = stored else { return }
        session.lastConversationId = id
        stored = session
        store.save(session)
    }

    private func forgetCurrentConversation(_ id: String?) {
        let shouldClear = id == nil || id?.isEmpty == true || currentConversationId == id
        if shouldClear {
            currentConversationId = nil
        }
        guard var session = stored else { return }
        if shouldClear {
            session.lastConversationId = nil
            stored = session
            store.save(session)
        }
    }

    private func rememberSeen(_ key: String) -> Bool {
        guard !key.isEmpty else { return true }
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
    }

    private func isExpired(_ exp: Int) -> Bool {
        guard let cfg = config else { return true }
        return Double(exp) - Date().timeIntervalSince1970 <= cfg.refreshLeewaySeconds
    }

    private func requireConfig() throws -> HermesLiveChatConfig {
        guard let config else {
            throw HermesLiveChatException(error: .notConfigured, code: nil, message: "configure() must be called first", status: nil)
        }
        return config
    }

    private func requireApi() throws -> ApiClient {
        guard let api else {
            throw HermesLiveChatException(error: .notConfigured, code: nil, message: "configure() must be called first", status: nil)
        }
        return api
    }

    private func emit(_ event: HermesLiveChatEvent) {
        continuations.values.forEach { $0.yield(event) }
    }
}
