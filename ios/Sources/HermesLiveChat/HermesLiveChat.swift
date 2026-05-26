import Foundation
import SwiftCentrifuge
import UIKit

public struct HermesLiveChatConfig {
    public let baseUrl: URL
    public let appKey: String
    public let realtimeUrl: URL
    public let refreshLeewaySeconds: TimeInterval

    public init(
        baseUrl: URL,
        appKey: String,
        realtimeUrl: URL? = nil,
        refreshLeewaySeconds: TimeInterval = 60
    ) {
        self.baseUrl = baseUrl
        self.appKey = appKey
        self.realtimeUrl = realtimeUrl ?? HermesLiveChatConfig.deriveRealtimeUrl(baseUrl)
        self.refreshLeewaySeconds = refreshLeewaySeconds
    }

    private static func deriveRealtimeUrl(_ baseUrl: URL) -> URL {
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/connection/websocket"
        components.query = nil
        return components.url!
    }
}

public struct VisitorIdentity: Codable {
    public var customerId: String?
    public var externalUserId: String?
    public var businessId: String?
    public var ticketId: String?
    public var number: String?
    public var email: String?
    public var name: String?
    public var avatar: String?
    public var locale: String?
    public var attrs: [String: String]?

    public init(
        customerId: String? = nil,
        externalUserId: String? = nil,
        businessId: String? = nil,
        ticketId: String? = nil,
        number: String? = nil,
        email: String? = nil,
        name: String? = nil,
        avatar: String? = nil,
        locale: String? = nil,
        attrs: [String: String]? = nil
    ) {
        self.customerId = customerId
        self.externalUserId = externalUserId
        self.businessId = businessId
        self.ticketId = ticketId
        self.number = number
        self.email = email
        self.name = name
        self.avatar = avatar
        self.locale = locale
        self.attrs = attrs
    }
}

public struct VisitorSession {
    public let visitorId: String
    public let contactId: Int
    public let tokenExp: Int
    public let realtimeUrl: URL
}

public enum LiveChatConnectionState {
    case idle
    case connecting
    case connected
    case disconnected
}

public enum HermesLiveChatError: Error {
    case notConfigured
    case network
    case badRequest
    case tokenInvalid
    case tokenExpired
    case invalidVisitorId
    case conversationForbidden
    case conversationClosed
    case messageRateLimited
    case contentInvalid
    case attachmentTooLarge
    case attachmentTypeInvalid
    case channelDisabled
    case domainNotAllowed
    case orgDisabled
    case realtimeConnectUnauthorized
    case realtimeProviderUnavailable
    case unknown
}

public struct HermesLiveChatException: Error {
    public let error: HermesLiveChatError
    public let code: String?
    public let message: String?
    public let status: Int?
}

public struct Conversation {
    public let uuid: String
    public let status: String
    public let channelType: String
    public let channelId: String
}

public struct Message: Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let conversationId: String
    public let clientMsgId: String
    public let senderType: String
    public let senderId: String
    public let contentType: String
    public let content: [String: Any]
    public let createdAt: Int

    public var displayText: String {
        if contentType == "text" {
            return content["text"] as? String ?? ""
        }
        if contentType == "image" {
            return content["url"] as? String ?? ""
        }
        return "[\(contentType)]"
    }
}

public enum HermesLiveChatEvent {
    case connectionStateChanged(LiveChatConnectionState)
    case messageReceived(Message, Conversation)
    case conversationUpdated(Conversation)
    case messageRead(conversationId: String, messageId: String, readAt: Int)
    case error(HermesLiveChatException)
}

public final class HermesLiveChat {
    public static let shared = HermesLiveChat()

    private var config: HermesLiveChatConfig?
    private var api: ApiClient?
    private var realtime: RealtimeClient?
    private var stored: StoredSession?
    private var seen = Set<String>()
    private let store = SessionStore()
    private var continuations: [UUID: AsyncStream<HermesLiveChatEvent>.Continuation] = [:]

    public private(set) var currentConversationId: String?

    private init() {}

    public func configure(_ config: HermesLiveChatConfig) {
        self.config = config
        self.api = ApiClient(config: config)
        self.realtime = RealtimeClient { [weak self] event in
            self?.emit(event)
        }
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
        let config = json["config"] as? [String: Any]
        return config?["welcome"] as? String ?? ""
    }

    @discardableResult
    public func startSession(_ identity: VisitorIdentity) async throws -> VisitorSession {
        let cfg = try requireConfig()
        let cached = store.load(appKey: cfg.appKey)
        currentConversationId = cached?.lastConversationId
        let oldToken = cached.flatMap { isExpired($0.tokenExp) ? nil : $0.token }
        let json = try await requireApi().initSession(identity: identity, oldVisitorToken: oldToken)
        let realtimeUrl = ((json["realtime"] as? [String: Any])?["url"] as? String)
            .flatMap(URL.init(string:)) ?? cfg.realtimeUrl
        let session = StoredSession(
            appKey: cfg.appKey,
            visitorId: json["visitor_id"] as? String ?? "",
            contactId: json["contact_id"] as? Int ?? 0,
            token: json["token"] as? String ?? "",
            tokenExp: json["token_exp"] as? Int ?? 0,
            lastConversationId: currentConversationId
        )
        stored = session
        store.save(session)
        realtime?.connect(url: realtimeUrl, token: session.token)
        return VisitorSession(
            visitorId: session.visitorId,
            contactId: session.contactId,
            tokenExp: session.tokenExp,
            realtimeUrl: realtimeUrl
        )
    }

    public func sendText(_ text: String, conversationId: String? = nil) async throws -> Message {
        let token = try await validToken()
        let message = try await requireApi().sendText(
            token: token,
            conversationId: conversationId ?? currentConversationId,
            text: text,
            clientMsgId: "c_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        )
        rememberConversation(message.conversationId)
        rememberSeen(message.uuid)
        rememberSeen(message.clientMsgId)
        return message
    }

    public func sendImage(
        data: Data,
        mimeType: String,
        filename: String? = nil,
        conversationId: String? = nil
    ) async throws -> Message {
        let token = try await validToken()
        let presign = try await requireApi().presign(
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
        try await requireApi().uploadPresigned(
            url: uploadURL,
            method: presign["method"] as? String ?? "PUT",
            headers: presign["headers"] as? [String: String] ?? [:],
            data: data
        )
        let message = try await requireApi().sendImage(
            token: token,
            conversationId: conversationId ?? currentConversationId,
            key: key,
            url: downloadURL,
            mimeType: mimeType,
            size: data.count,
            clientMsgId: "c_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        )
        rememberConversation(message.conversationId)
        rememberSeen(message.uuid)
        rememberSeen(message.clientMsgId)
        return message
    }

    public func history(conversationId: String, afterId: String? = nil, limit: Int = 50) async throws -> [Message] {
        let messages = try await requireApi().history(
            token: try await validToken(),
            conversationId: conversationId,
            afterId: afterId,
            limit: limit
        )
        rememberConversation(conversationId)
        return messages
    }

    public func markRead(conversationId: String, messageId: String) async throws {
        try await requireApi().markRead(token: try await validToken(), messageId: messageId)
        rememberConversation(conversationId)
    }

    public func disconnect() {
        realtime?.disconnect()
    }

    public func destroy() {
        disconnect()
        stored = nil
        currentConversationId = nil
        seen.removeAll()
    }

    fileprivate func handlePublication(_ json: [String: Any]) {
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
            rememberConversation(conversation.uuid)
            emit(.messageReceived(message, conversation))
        case "livechat.conversation.updated":
            guard let c = json["conversation"] as? [String: Any] else { return }
            let conversation = Conversation.from(c)
            rememberConversation(conversation.uuid)
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
        let json = try await requireApi().initSession(identity: VisitorIdentity(), oldVisitorToken: session.token)
        let next = StoredSession(
            appKey: session.appKey,
            visitorId: json["visitor_id"] as? String ?? session.visitorId,
            contactId: json["contact_id"] as? Int ?? session.contactId,
            token: json["token"] as? String ?? session.token,
            tokenExp: json["token_exp"] as? Int ?? session.tokenExp,
            lastConversationId: session.lastConversationId
        )
        stored = next
        store.save(next)
        return next.token
    }

    private func rememberConversation(_ id: String) {
        guard !id.isEmpty else { return }
        currentConversationId = id
        if let session = stored {
            let next = StoredSession(
                appKey: session.appKey,
                visitorId: session.visitorId,
                contactId: session.contactId,
                token: session.token,
                tokenExp: session.tokenExp,
                lastConversationId: id
            )
            stored = next
            store.save(next)
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

private final class ApiClient {
    let config: HermesLiveChatConfig
    let session = URLSession(configuration: .default)

    init(config: HermesLiveChatConfig) {
        self.config = config
    }

    func publicConfig(locale: String?) async throws -> [String: Any] {
        try await get(
            path: "/api/livechat/v1/public-config",
            query: [
                "channel_type": "app",
                "app_key": config.appKey,
                "locale": locale,
            ].compactMapValues { $0 }
        )
    }

    func initSession(identity: VisitorIdentity, oldVisitorToken: String?) async throws -> [String: Any] {
        var body: [String: Any] = [
            "channel_type": "app",
            "app_key": config.appKey,
            "user": [
                "email": identity.email,
                "name": identity.name,
                "avatar": identity.avatar,
            ].compactMapValues { $0 },
        ]
        body["customer_id"] = identity.customerId
        body["external_user_id"] = identity.externalUserId
        body["business_id"] = identity.businessId
        body["ticket_id"] = identity.ticketId
        body["number"] = identity.number
        body["locale"] = identity.locale
        body["attrs"] = identity.attrs
        return try await post(path: "/api/livechat/v1/init", body: body.compactMapValues { $0 }, token: oldVisitorToken)
    }

    func sendText(token: String, conversationId: String?, text: String, clientMsgId: String) async throws -> Message {
        var body: [String: Any] = [
            "client_msg_id": clientMsgId,
            "content_type": "text",
            "content": ["text": text],
        ]
        body["conversation_id"] = conversationId
        return Message.from(try await messageEnvelope(post(path: "/api/livechat/v1/messages", body: body.compactMapValues { $0 }, token: token)))
    }

    func sendImage(token: String, conversationId: String?, key: String, url: String, mimeType: String, size: Int, clientMsgId: String) async throws -> Message {
        var body: [String: Any] = [
            "client_msg_id": clientMsgId,
            "content_type": "image",
            "content": ["key": key, "url": url, "mime": mimeType, "size": size],
        ]
        body["conversation_id"] = conversationId
        return Message.from(try await messageEnvelope(post(path: "/api/livechat/v1/messages", body: body.compactMapValues { $0 }, token: token)))
    }

    func markRead(token: String, messageId: String) async throws {
        _ = try await post(path: "/api/livechat/v1/messages/\(messageId.urlEncoded)/read", body: nil, token: token)
    }

    func history(token: String, conversationId: String, afterId: String?, limit: Int) async throws -> [Message] {
        let json = try await get(
            path: "/api/livechat/v1/conversations/\(conversationId.urlEncoded)/messages",
            query: [
                "limit": "\(limit)",
                "after_id": afterId,
            ].compactMapValues { $0 },
            token: token
        )
        return (json["items"] as? [[String: Any]] ?? []).map(Message.from)
    }

    func presign(token: String, filename: String, mimeType: String, size: Int) async throws -> [String: Any] {
        try await post(
            path: "/api/livechat/v1/attachments/presign",
            body: ["filename": filename, "mime": mimeType, "size": size],
            token: token
        )
    }

    func uploadPresigned(url: URL, method: String, headers: [String: String], data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard status < 300 else {
            throw HermesLiveChatException(error: .attachmentTypeInvalid, code: nil, message: "attachment upload failed", status: status)
        }
    }

    private func get(path: String, query: [String: String], token: String? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: config.baseUrl.liveChatAppendingPath(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await execute(request)
    }

    private func post(path: String, body: [String: Any]?, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: config.baseUrl.liveChatAppendingPath(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        let payload = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let code = payload["code"].flatMap { Int("\($0)") }
        if status < 200 || status >= 300 || (code != nil && code != 0) {
            throw HermesLiveChatException(
                error: mapBackendError(status: status, code: payload["code"].map { "\($0)" }),
                code: payload["code"].map { "\($0)" },
                message: payload["msg"] as? String,
                status: status
            )
        }
        if payload.keys.contains("code"), let data = payload["data"] as? [String: Any] {
            return data
        }
        return payload
    }

    private func messageEnvelope(_ json: [String: Any]) -> [String: Any] {
        json["message"] as? [String: Any] ?? json
    }
}

private final class RealtimeClient: CentrifugeClientDelegate {
    private var client: CentrifugeClient?
    private let emit: (HermesLiveChatEvent) -> Void

    init(emit: @escaping (HermesLiveChatEvent) -> Void) {
        self.emit = emit
    }

    func connect(url: URL, token: String) {
        disconnect()
        let config = CentrifugeClientConfig(token: token)
        let client = CentrifugeClient(endpoint: url.absoluteString, config: config, delegate: self)
        self.client = client
        client.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        emit(.connectionStateChanged(.idle))
    }

    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        emit(.connectionStateChanged(.connecting))
    }

    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        emit(.connectionStateChanged(.connected))
    }

    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        emit(.connectionStateChanged(.disconnected))
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
        guard let json = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any] else { return }
        HermesLiveChat.shared.handlePublication(json)
    }

    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        emit(.error(HermesLiveChatException(error: .unknown, code: nil, message: "\(event.error)", status: nil)))
    }
}

private struct StoredSession: Codable {
    let appKey: String
    let visitorId: String
    let contactId: Int
    let token: String
    let tokenExp: Int
    let lastConversationId: String?
}

private final class SessionStore {
    func load(appKey: String) -> StoredSession? {
        guard let data = UserDefaults.standard.data(forKey: "hermes.livechat.session.\(appKey)") else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: "hermes.livechat.session.\(session.appKey)")
        }
    }
}

public final class HermesLiveChatLauncher {
    public static func present(
        from viewController: UIViewController,
        identity: VisitorIdentity,
        title: String = "在线客服",
        locale: String? = nil,
        startSessionOnOpen: Bool = false
    ) {
        let page = HermesLiveChatViewController(
            identity: identity,
            title: title,
            locale: locale,
            startSessionOnOpen: startSessionOnOpen
        )
        viewController.navigationController?.pushViewController(page, animated: true)
            ?? viewController.present(UINavigationController(rootViewController: page), animated: true)
    }
}

public final class HermesLiveChatViewController: UIViewController {
    private let identity: VisitorIdentity
    private let locale: String?
    private let startSessionOnOpen: Bool
    private let stack = UIStackView()
    private let input = UITextField()
    private var messageKeys = Set<String>()
    private var started = false
    private var eventsTask: Task<Void, Never>?

    public init(
        identity: VisitorIdentity,
        title: String = "在线客服",
        locale: String? = nil,
        startSessionOnOpen: Bool = false
    ) {
        self.identity = identity
        self.locale = locale
        self.startSessionOnOpen = startSessionOnOpen
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        observeEvents()
        Task {
            await loadWelcome()
            if startSessionOnOpen {
                await ensureSession()
            }
        }
    }

    deinit {
        eventsTask?.cancel()
    }

    private func buildUI() {
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        input.placeholder = "输入消息"
        input.borderStyle = .roundedRect
        let send = UIButton(type: .system)
        send.setTitle("发送", for: .normal)
        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let composer = UIStackView(arrangedSubviews: [input, send])
        composer.spacing = 8
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func observeEvents() {
        eventsTask = Task {
            for await event in HermesLiveChat.shared.events() {
                await MainActor.run {
                    switch event {
                    case .messageReceived(let message, _):
                        addMessage(message)
                    case .conversationUpdated(let conversation):
                        if conversation.status == "closed" { input.isEnabled = false }
                    case .error(let error):
                        addSystem(error.message ?? "\(error.error)")
                    default:
                        break
                    }
                }
            }
        }
    }

    private func loadWelcome() async {
        do {
            let welcome = try await HermesLiveChat.shared.prefetchWelcome(locale: locale)
            if !welcome.isEmpty { await MainActor.run { addSystem(welcome) } }
        } catch {
            await MainActor.run { addSystem("加载欢迎语失败") }
        }
    }

    private func ensureSession() async {
        guard !started else { return }
        do {
            try await HermesLiveChat.shared.startSession(identity)
            started = true
            if let id = HermesLiveChat.shared.currentConversationId {
                let messages = try await HermesLiveChat.shared.history(conversationId: id)
                await MainActor.run { messages.forEach(addMessage) }
            }
        } catch {
            await MainActor.run { addSystem("初始化会话失败") }
        }
    }

    @objc private func sendTapped() {
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        input.text = ""
        Task {
            await ensureSession()
            do {
                let message = try await HermesLiveChat.shared.sendText(text)
                await MainActor.run { addMessage(message) }
            } catch {
                await MainActor.run {
                    input.text = text
                    addSystem("发送失败")
                }
            }
        }
    }

    private func addSystem(_ text: String) {
        addBubble(text, mine: false)
    }

    private func addMessage(_ message: Message) {
        if let key = messageKey(message), !messageKeys.insert(key).inserted {
            return
        }
        addBubble(message.displayText, mine: message.senderType == "visitor")
    }

    private func messageKey(_ message: Message) -> String? {
        let uuid = message.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !uuid.isEmpty { return uuid }
        let clientMsgId = message.clientMsgId.trimmingCharacters(in: .whitespacesAndNewlines)
        return clientMsgId.isEmpty ? nil : clientMsgId
    }

    private func addBubble(_ text: String, mine: Bool) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = mine ? .right : .left
        label.backgroundColor = mine ? .systemBlue : .secondarySystemBackground
        label.textColor = mine ? .white : .label
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(label)
    }
}

private extension Conversation {
    static func from(_ json: [String: Any]) -> Conversation {
        Conversation(
            uuid: json["uuid"] as? String ?? "",
            status: json["status"] as? String ?? "",
            channelType: json["channel_type"] as? String ?? "",
            channelId: json["channel_id"] as? String ?? ""
        )
    }
}

private extension Message {
    static func from(_ json: [String: Any]) -> Message {
        Message(
            uuid: json["uuid"] as? String ?? "",
            conversationId: json["conversation_id"] as? String ?? "",
            clientMsgId: json["client_msg_id"] as? String ?? "",
            senderType: json["sender_type"] as? String ?? "",
            senderId: json["sender_id"] as? String ?? "",
            contentType: json["content_type"] as? String ?? "",
            content: json["content"] as? [String: Any] ?? [:],
            createdAt: json["created_at"] as? Int ?? 0
        )
    }
}

private extension URL {
    func liveChatAppendingPath(_ rawPath: String) -> URL {
        var url = self
        rawPath.split(separator: "/").forEach { url.appendPathComponent(String($0)) }
        return url
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private func defaultImageFilename(mimeType: String) -> String {
    "image_\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).\(imageExtension(mimeType: mimeType))"
}

private func imageExtension(mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": return "png"
    case "image/gif": return "gif"
    default: return "jpg"
    }
}

private func mapBackendError(status: Int, code: String?) -> HermesLiveChatError {
    switch code {
    case "70001": return .badRequest
    case "70002", "LC_TOKEN_INVALID": return .tokenInvalid
    case "70003", "LC_TOKEN_EXPIRED": return .tokenExpired
    case "70004", "LC_INVALID_VISITOR_ID": return .invalidVisitorId
    case "70024", "LC_CONV_FORBIDDEN": return .conversationForbidden
    case "70025", "LC_CONV_CLOSED": return .conversationClosed
    case "LC_MESSAGE_RATE_LIMITED": return .messageRateLimited
    case "LC_CONTENT_INVALID": return .contentInvalid
    case "70030", "LC_ATTACHMENT_TOO_LARGE": return .attachmentTooLarge
    case "70031", "LC_ATTACHMENT_TYPE_INVALID", "LC_ATTACHMENT_TYPE_NOT_ALLOWED": return .attachmentTypeInvalid
    case "70011", "LC_CHANNEL_DISABLED": return .channelDisabled
    case "70012", "LC_DOMAIN_NOT_ALLOWED": return .domainNotAllowed
    case "70010", "LC_ORG_LIVECHAT_DISABLED": return .orgDisabled
    case "LC_REALTIME_CONNECT_UNAUTHORIZED": return .realtimeConnectUnauthorized
    case "70050", "LC_REALTIME_PROVIDER_UNAVAILABLE": return .realtimeProviderUnavailable
    default:
        if status == 400 { return .badRequest }
        if status == 401 { return .tokenInvalid }
        if status == 403 { return .conversationForbidden }
        if status >= 500 { return .realtimeProviderUnavailable }
        return .unknown
    }
}
