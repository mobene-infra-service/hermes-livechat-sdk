package com.mobene.hermes.livechat

import com.mobene.hermes.livechat.internal.optLongOrNull
import com.mobene.hermes.livechat.internal.optStringOrNull
import com.mobene.hermes.livechat.internal.toMap
import org.json.JSONArray
import org.json.JSONObject

data class VisitorIdentity(
    val customerId: String? = null,
    val externalUserId: String? = null,
    val businessId: String? = null,
    val ticketId: String? = null,
    val number: String? = null,
    val email: String? = null,
    val name: String? = null,
    val avatar: String? = null,
    val locale: String? = null,
    val attrs: Map<String, Any?>? = null,
    val identityToken: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        putOpt("customer_id", customerId)
        putOpt("external_user_id", externalUserId)
        putOpt("business_id", businessId)
        putOpt("ticket_id", ticketId)
        putOpt("number", number)
        putOpt("email", email)
        putOpt("name", name)
        putOpt("avatar", avatar)
        putOpt("locale", locale)
        putOpt("identity_token", identityToken)
        if (attrs != null) put("attrs", JSONObject(attrs))
    }

    companion object {
        fun fromJson(raw: String): VisitorIdentity {
            val json = JSONObject(raw)
            val attrs = json.optJSONObject("attrs")?.toMap()
            return VisitorIdentity(
                customerId = json.optStringOrNull("customer_id"),
                externalUserId = json.optStringOrNull("external_user_id"),
                businessId = json.optStringOrNull("business_id"),
                ticketId = json.optStringOrNull("ticket_id"),
                number = json.optStringOrNull("number"),
                email = json.optStringOrNull("email"),
                name = json.optStringOrNull("name"),
                avatar = json.optStringOrNull("avatar"),
                locale = json.optStringOrNull("locale"),
                attrs = attrs,
                identityToken = json.optStringOrNull("identity_token"),
            )
        }
    }
}

data class VisitorSession(
    val visitorId: String,
    val contactId: Long,
    val tokenExp: Long,
    val realtimeUrl: String,
)

data class Conversation(
    val uuid: String,
    val status: String,
    val assigneeType: String?,
    val assigneeCode: String?,
    val channelType: String,
    val channelId: String,
    val lastMessageAt: Long?,
    val lastMessagePreview: String?,
    val unreadCountVisitor: Int,
    val createdAt: Long?,
    val closedBy: String?,
) {
    companion object {
        fun fromJson(json: JSONObject): Conversation = Conversation(
            uuid = json.getString("uuid"),
            status = json.getString("status"),
            assigneeType = json.optStringOrNull("assignee_type"),
            assigneeCode = json.optStringOrNull("assignee_code"),
            channelType = json.getString("channel_type"),
            channelId = json.getString("channel_id"),
            lastMessageAt = json.optLongOrNull("last_message_at"),
            lastMessagePreview = json.optStringOrNull("last_message_preview"),
            unreadCountVisitor = json.optInt("unread_count_visitor", 0),
            createdAt = json.optLongOrNull("created_at"),
            closedBy = json.optStringOrNull("closed_by"),
        )
    }
}

data class Message(
    val uuid: String,
    val conversationId: String,
    val clientMsgId: String,
    val senderType: String,
    val senderId: String,
    val contentType: String,
    val content: JSONObject,
    val status: String?,
    val readAt: Long?,
    val createdAt: Long,
) {
    companion object {
        fun fromJson(json: JSONObject): Message = Message(
            uuid = json.getString("uuid"),
            conversationId = json.optString("conversation_id", ""),
            clientMsgId = json.optString("client_msg_id", ""),
            senderType = json.getString("sender_type"),
            senderId = json.getString("sender_id"),
            contentType = json.getString("content_type"),
            content = json.optJSONObject("content") ?: JSONObject(),
            status = json.optStringOrNull("status"),
            readAt = json.optLongOrNull("read_at"),
            createdAt = json.optLong("created_at", 0),
        )
    }
}

data class SendMessageResult(
    val conversation: Conversation?,
    val message: Message,
    val messages: List<Message>,
) {
    companion object {
        fun fromJson(json: JSONObject): SendMessageResult {
            val conversation = json.optJSONObject("conversation")?.let { Conversation.fromJson(it) }
            // The server may envelope the primary message under "message" or
            // emit it at the top level alongside its conversation context.
            val message = Message.fromJson(json.optJSONObject("message") ?: json)
            val items = json.optJSONArray("messages") ?: JSONArray()
            val messages = (0 until items.length()).map { Message.fromJson(items.getJSONObject(it)) }
            return SendMessageResult(conversation, message, messages.ifEmpty { listOf(message) })
        }
    }
}

data class ConversationEvent(
    val eventType: String,
    val createdAt: Long,
    val fromStatus: String?,
    val toStatus: String?,
    val actorType: String?,
    val actorId: String?,
    val payload: JSONObject?,
) {
    companion object {
        fun fromJson(json: JSONObject): ConversationEvent = ConversationEvent(
            eventType = json.getString("event_type"),
            createdAt = json.optLong("created_at", 0),
            fromStatus = json.optStringOrNull("from_status"),
            toStatus = json.optStringOrNull("to_status"),
            actorType = json.optStringOrNull("actor_type"),
            actorId = json.optStringOrNull("actor_id"),
            payload = json.optJSONObject("payload"),
        )
    }
}
