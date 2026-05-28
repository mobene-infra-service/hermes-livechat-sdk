package com.mobene.hermes.livechat

enum class LiveChatConnectionState { IDLE, CONNECTING, CONNECTED, DISCONNECTED }

sealed class HermesLiveChatEvent {
    data class ConnectionStateChanged(val state: LiveChatConnectionState) : HermesLiveChatEvent()
    data class MessageReceived(val message: Message, val conversation: Conversation) : HermesLiveChatEvent()
    data class ConversationUpdated(
        val conversation: Conversation,
        val event: ConversationEvent?,
    ) : HermesLiveChatEvent()
    data class MessageRead(
        val conversationId: String,
        val messageId: String,
        val readAt: Long,
        val readerType: String?,
    ) : HermesLiveChatEvent()
    data class Error(val error: HermesLiveChatException) : HermesLiveChatEvent()
}
