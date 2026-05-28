import Foundation

public enum HermesLiveChatEvent {
    case connectionStateChanged(LiveChatConnectionState)
    case messageReceived(Message, Conversation)
    case conversationUpdated(Conversation)
    case messageRead(conversationId: String, messageId: String, readAt: Int)
    case error(HermesLiveChatException)
}
