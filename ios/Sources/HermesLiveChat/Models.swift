import Foundation

public struct Conversation {
    public let uuid: String
    public let status: String
    public let channelType: String
    public let channelId: String
}

internal extension Conversation {
    static func from(_ json: [String: Any]) -> Conversation {
        Conversation(
            uuid: json["uuid"] as? String ?? "",
            status: json["status"] as? String ?? "",
            channelType: json["channel_type"] as? String ?? "",
            channelId: json["channel_id"] as? String ?? ""
        )
    }
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
    public let readAt: Int?
    public let createdAt: Int

    public var displayText: String {
        if contentType == "text" || contentType == "welcome" || contentType == "close" {
            return content["text"] as? String ?? ""
        }
        if contentType == "image" {
            return content["url"] as? String ?? ""
        }
        return "[\(contentType)]"
    }
}

internal extension Message {
    static func from(_ json: [String: Any]) -> Message {
        Message(
            uuid: json["uuid"] as? String ?? "",
            conversationId: json["conversation_id"] as? String ?? "",
            clientMsgId: json["client_msg_id"] as? String ?? "",
            senderType: json["sender_type"] as? String ?? "",
            senderId: json["sender_id"] as? String ?? "",
            contentType: json["content_type"] as? String ?? "",
            content: json["content"] as? [String: Any] ?? [:],
            readAt: json["read_at"] as? Int,
            createdAt: json["created_at"] as? Int ?? 0
        )
    }
}

internal struct SendMessageResult {
    let conversation: Conversation?
    let message: Message
    let messages: [Message]

    static func from(_ json: [String: Any]) -> SendMessageResult {
        let conversation = (json["conversation"] as? [String: Any]).map(Conversation.from)
        // The server may envelope the primary message under "message" or emit
        // it at the top level alongside its conversation context.
        let envelope = (json["message"] as? [String: Any]) ?? json
        let message = Message.from(envelope)
        let messages = (json["messages"] as? [[String: Any]] ?? []).map(Message.from)
        return SendMessageResult(
            conversation: conversation,
            message: message,
            messages: messages.isEmpty ? [message] : messages
        )
    }
}
