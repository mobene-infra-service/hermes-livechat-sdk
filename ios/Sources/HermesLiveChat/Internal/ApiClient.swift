import Foundation

internal final class ApiClient {
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
        body["identity_token"] = identity.identityToken
        return try await post(path: "/api/livechat/v1/init", body: body.compactMapValues { $0 }, token: oldVisitorToken)
    }

    func sendText(token: String, conversationId: String?, text: String, clientMsgId: String) async throws -> SendMessageResult {
        var body: [String: Any] = [
            "client_msg_id": clientMsgId,
            "content_type": "text",
            "content": ["text": text],
        ]
        body["conversation_id"] = conversationId
        return SendMessageResult.from(try await post(path: "/api/livechat/v1/messages", body: body.compactMapValues { $0 }, token: token))
    }

    func sendImage(token: String, conversationId: String?, key: String, url: String, mimeType: String, size: Int, clientMsgId: String) async throws -> SendMessageResult {
        var body: [String: Any] = [
            "client_msg_id": clientMsgId,
            "content_type": "image",
            "content": ["key": key, "url": url, "mime": mimeType, "size": size],
        ]
        body["conversation_id"] = conversationId
        return SendMessageResult.from(try await post(path: "/api/livechat/v1/messages", body: body.compactMapValues { $0 }, token: token))
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

    func listConversations(token: String) async throws -> [Conversation] {
        let json = try await get(
            path: "/api/livechat/v1/conversations",
            query: ["limit": "20"],
            token: token
        )
        return (json["items"] as? [[String: Any]] ?? []).map(Conversation.from)
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
}
