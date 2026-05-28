package com.mobene.hermes.livechat

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.centrifugal.centrifuge.Client
import io.github.centrifugal.centrifuge.ConnectedEvent
import io.github.centrifugal.centrifuge.ConnectingEvent
import io.github.centrifugal.centrifuge.DisconnectedEvent
import io.github.centrifugal.centrifuge.ErrorEvent
import io.github.centrifugal.centrifuge.EventListener
import io.github.centrifugal.centrifuge.Options
import io.github.centrifugal.centrifuge.ServerPublicationEvent
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

data class HermesLiveChatConfig(
    val baseUrl: String,
    val appKey: String,
    val realtimeUrl: String = deriveRealtimeUrl(baseUrl),
    val refreshLeewaySeconds: Long = 60,
    val requestTimeoutMillis: Long = 10_000,
    val realtimeIdleDisconnectMillis: Long = 5 * 60 * 1000L,
)

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

enum class LiveChatConnectionState { IDLE, CONNECTING, CONNECTED, DISCONNECTED }

enum class HermesLiveChatError {
    NOT_CONFIGURED,
    NETWORK,
    BAD_REQUEST,
    TOKEN_INVALID,
    TOKEN_EXPIRED,
    INVALID_VISITOR_ID,
    CONVERSATION_FORBIDDEN,
    CONVERSATION_CLOSED,
    MESSAGE_RATE_LIMITED,
    CONTENT_INVALID,
    ATTACHMENT_TOO_LARGE,
    ATTACHMENT_TYPE_INVALID,
    CHANNEL_DISABLED,
    DOMAIN_NOT_ALLOWED,
    ORG_DISABLED,
    APP_INIT_TOKEN_INVALID,
    APP_INIT_TOKEN_EXPIRED,
    REALTIME_CONNECT_UNAUTHORIZED,
    REALTIME_PROVIDER_UNAVAILABLE,
    UNKNOWN,
}

class HermesLiveChatException(
    val error: HermesLiveChatError,
    val backendCode: String? = null,
    override val message: String? = null,
    val status: Int? = null,
) : Exception(message)

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

object HermesLiveChat {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _events = MutableSharedFlow<HermesLiveChatEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<HermesLiveChatEvent> = _events

    private var config: HermesLiveChatConfig? = null
    private var api: ApiClient? = null
    private var store: SessionStore? = null
    private var realtime: CentrifugeRealtime? = null
    private var stored: StoredSession? = null
    private var realtimeIdleJob: Job? = null
    private var realtimeUrl: String? = null
    private var realtimeToken: String? = null
    private var realtimeState: LiveChatConnectionState = LiveChatConnectionState.IDLE
    private val seen = LinkedHashSet<String>()

    var currentConversationId: String? = null
        private set

    fun configure(context: Context, config: HermesLiveChatConfig) {
        disconnectRealtime()
        this.config = config
        api = ApiClient(config)
        store = SessionStore(context.applicationContext)
        realtime = CentrifugeRealtime { emitRealtimeEvent(it) }
        currentConversationId = null
        stored = null
        seen.clear()
    }

    suspend fun prefetchWelcome(locale: String? = null): String {
        val json = requireApi().publicConfig(locale)
        json.optString("welcome").takeIf { it.isNotEmpty() }?.let { return it }
        val cfg = json.optJSONObject("config")
        return cfg?.optString("welcome").orEmpty()
    }

    suspend fun startSession(identity: VisitorIdentity): VisitorSession {
        val cfg = requireConfig()
        val cached = store?.load(cfg.appKey)
        currentConversationId = cached?.lastConversationId
        val oldToken = cached?.takeIf { !isExpired(it.tokenExp) }?.token
        val json = requireApi().init(identity, oldToken)
        val realtimeUrl = json.optJSONObject("realtime")?.optString("url")?.takeIf { it.isNotEmpty() }
            ?: cfg.realtimeUrl
        val next = StoredSession(
            appKey = cfg.appKey,
            visitorId = json.getString("visitor_id"),
            contactId = json.getLong("contact_id"),
            token = json.getString("token"),
            tokenExp = json.getLong("token_exp"),
            realtimeUrl = realtimeUrl,
            lastConversationId = currentConversationId,
        )
        stored = next
        store?.save(next)
        refreshCurrentConversation(next.token)
        connectRealtime(realtimeUrl, next.token)
        return VisitorSession(next.visitorId, next.contactId, next.tokenExp, realtimeUrl)
    }

    suspend fun sendText(text: String, conversationId: String? = null): Message {
        var token = validToken()
        val clientMsgId = newClientMsgId()
        val implicitConversation = conversationId == null
        if (implicitConversation && currentConversationId.isNullOrEmpty()) {
            token = ensureActiveConversation(token)
        }
        ensureRealtimeConnected(token)
        val convId = conversationId ?: currentConversationId
        val message = try {
            requireApi().sendText(
                token = token,
                conversationId = convId,
                text = text,
                clientMsgId = clientMsgId,
            )
        } catch (error: HermesLiveChatException) {
            if (!implicitConversation || error.error != HermesLiveChatError.CONVERSATION_CLOSED) {
                throw error
            }
            forgetCurrentConversation(convId)
            requireApi().sendText(
                token = token,
                conversationId = null,
                text = text,
                clientMsgId = clientMsgId,
            )
        }
        rememberConversation(message.conversationId)
        rememberSeen(message.uuid)
        rememberSeen(message.clientMsgId)
        touchRealtimeActivity()
        return message
    }

    suspend fun sendImage(
        bytes: ByteArray,
        mimeType: String,
        filename: String? = null,
        conversationId: String? = null,
    ): Message {
        var token = validToken()
        val presign = requireApi().presign(token, filename ?: defaultImageFilename(mimeType), mimeType, bytes.size)
        requireApi().uploadPresigned(
            url = presign.getString("upload_url"),
            method = presign.optString("method", "PUT"),
            headers = presign.optJSONObject("headers")?.toStringMap().orEmpty(),
            bytes = bytes,
            mimeType = mimeType,
        )
        val key = presign.getString("key")
        val url = presign.getString("download_url")
        val clientMsgId = newClientMsgId()
        val implicitConversation = conversationId == null
        if (implicitConversation && currentConversationId.isNullOrEmpty()) {
            token = ensureActiveConversation(token)
        }
        ensureRealtimeConnected(token)
        val convId = conversationId ?: currentConversationId
        val message = try {
            requireApi().sendImage(
                token = token,
                conversationId = convId,
                key = key,
                url = url,
                mimeType = mimeType,
                size = bytes.size,
                clientMsgId = clientMsgId,
            )
        } catch (error: HermesLiveChatException) {
            if (!implicitConversation || error.error != HermesLiveChatError.CONVERSATION_CLOSED) {
                throw error
            }
            forgetCurrentConversation(convId)
            requireApi().sendImage(
                token = token,
                conversationId = null,
                key = key,
                url = url,
                mimeType = mimeType,
                size = bytes.size,
                clientMsgId = clientMsgId,
            )
        }
        rememberConversation(message.conversationId)
        rememberSeen(message.uuid)
        rememberSeen(message.clientMsgId)
        touchRealtimeActivity()
        return message
    }

    suspend fun markRead(conversationId: String, messageId: String) {
        requireApi().markRead(validToken(), messageId)
        rememberConversation(conversationId)
    }

    suspend fun history(
        conversationId: String,
        afterId: String? = null,
        limit: Int = 50,
    ): List<Message> {
        val messages = requireApi().history(validToken(), conversationId, afterId, limit)
        rememberConversation(conversationId)
        return messages.sortedWith(
            compareBy<Message> { it.createdAt }
                .thenBy { messageSortRank(it) }
                .thenBy { it.uuid },
        )
    }

    private fun messageSortRank(message: Message): Int = when (message.contentType) {
        "welcome" -> 0
        "close" -> 2
        else -> 1
    }

    fun disconnect() {
        disconnectRealtime()
    }

    fun destroy() {
        disconnect()
        stored = null
        currentConversationId = null
        seen.clear()
    }

    internal fun handlePublication(payload: JSONObject) {
        touchRealtimeActivity()
        val eventId = payload.optStringOrNull("event_id")
        if (eventId != null && !rememberSeen(eventId)) return
        when (payload.optString("type")) {
            "livechat.message.created" -> {
                val messageJson = payload.optJSONObject("message") ?: return
                val convJson = payload.optJSONObject("conversation") ?: return
                val message = Message.fromJson(messageJson)
                if (!rememberSeen(message.uuid) || !rememberSeen(message.clientMsgId)) return
                val conversation = Conversation.fromJson(convJson)
                rememberPublicationConversation(conversation)
                _events.tryEmit(HermesLiveChatEvent.MessageReceived(message, conversation))
            }
            "livechat.conversation.updated" -> {
                val convJson = payload.optJSONObject("conversation") ?: return
                val conversation = Conversation.fromJson(convJson)
                rememberPublicationConversation(conversation)
                val convEvent = payload.optJSONObject("event")?.let { ConversationEvent.fromJson(it) }
                _events.tryEmit(HermesLiveChatEvent.ConversationUpdated(conversation, convEvent))
            }
            "livechat.message.read" -> {
                val conv = payload.optJSONObject("conversation") ?: return
                val msg = payload.optJSONObject("message") ?: return
                _events.tryEmit(
                    HermesLiveChatEvent.MessageRead(
                        conversationId = conv.getString("uuid"),
                        messageId = msg.getString("uuid"),
                        readAt = msg.optLong("read_at", 0),
                        readerType = msg.optStringOrNull("reader_type"),
                    ),
                )
            }
        }
    }

    private suspend fun validToken(): String {
        val cfg = requireConfig()
        val session = stored ?: store?.load(cfg.appKey) ?: throw HermesLiveChatException(
            HermesLiveChatError.NOT_CONFIGURED,
            message = "startSession() must be called before this operation",
        )
        stored = session
        currentConversationId = currentConversationId ?: session.lastConversationId
        if (!isExpired(session.tokenExp)) return session.token
        val json = requireApi().init(VisitorIdentity(), session.token)
        val realtimeUrl = json.optJSONObject("realtime")?.optString("url")?.takeIf { it.isNotEmpty() }
            ?: session.realtimeUrl
            ?: cfg.realtimeUrl
        val next = session.copy(
            visitorId = json.getString("visitor_id"),
            contactId = json.getLong("contact_id"),
            token = json.getString("token"),
            tokenExp = json.getLong("token_exp"),
            realtimeUrl = realtimeUrl,
        )
        stored = next
        store?.save(next)
        refreshCurrentConversation(next.token)
        connectRealtime(realtimeUrl, next.token)
        return next.token
    }

    private suspend fun refreshCurrentConversation(token: String) {
        runCatching {
            requireApi().conversations(token)
                .firstOrNull { it.status != "closed" }
                ?.let { rememberConversation(it.uuid) }
        }
    }

    private suspend fun ensureActiveConversation(token: String): String {
        refreshCurrentConversation(token)
        if (!currentConversationId.isNullOrEmpty()) return token
        val cfg = requireConfig()
        val session = stored ?: store?.load(cfg.appKey) ?: return token
        val json = requireApi().init(VisitorIdentity(), token)
        val realtimeUrl = json.optJSONObject("realtime")?.optString("url")?.takeIf { it.isNotEmpty() }
            ?: session.realtimeUrl
            ?: cfg.realtimeUrl
        val next = session.copy(
            visitorId = json.getString("visitor_id"),
            contactId = json.getLong("contact_id"),
            token = json.getString("token"),
            tokenExp = json.getLong("token_exp"),
            realtimeUrl = realtimeUrl,
        )
        stored = next
        store?.save(next)
        refreshCurrentConversation(next.token)
        connectRealtime(realtimeUrl, next.token)
        return next.token
    }

    private fun ensureRealtimeConnected(token: String) {
        val cfg = requireConfig()
        val session = stored ?: store?.load(cfg.appKey) ?: return
        connectRealtime(session.realtimeUrl ?: cfg.realtimeUrl, token)
    }

    private fun connectRealtime(url: String, token: String) {
        if (realtimeUrl == url &&
            realtimeToken == token &&
            (realtimeState == LiveChatConnectionState.CONNECTING ||
                realtimeState == LiveChatConnectionState.CONNECTED)
        ) {
            touchRealtimeActivity()
            return
        }
        realtime?.connect(url, token)
        realtimeUrl = url
        realtimeToken = token
        realtimeState = LiveChatConnectionState.CONNECTING
        touchRealtimeActivity()
    }

    private fun disconnectRealtime() {
        realtimeIdleJob?.cancel()
        realtimeIdleJob = null
        realtimeUrl = null
        realtimeToken = null
        realtimeState = LiveChatConnectionState.IDLE
        realtime?.disconnect()
    }

    private fun touchRealtimeActivity() {
        realtimeIdleJob?.cancel()
        val delayMillis = config?.realtimeIdleDisconnectMillis ?: return
        if (delayMillis <= 0) return
        realtimeIdleJob = scope.launch {
            delay(delayMillis)
            disconnectRealtime()
        }
    }

    private fun emitRealtimeEvent(event: HermesLiveChatEvent) {
        if (event is HermesLiveChatEvent.ConnectionStateChanged) {
            realtimeState = event.state
            if (event.state == LiveChatConnectionState.IDLE) {
                realtimeUrl = null
                realtimeToken = null
            }
        }
        _events.tryEmit(event)
    }

    private fun rememberPublicationConversation(conversation: Conversation) {
        if (conversation.status == "closed") {
            forgetCurrentConversation(conversation.uuid)
            return
        }
        rememberConversation(conversation.uuid)
    }

    private fun rememberConversation(id: String) {
        if (id.isEmpty()) return
        currentConversationId = id
        val session = stored ?: return
        stored = session.copy(lastConversationId = id)
        store?.save(stored!!)
    }

    private fun forgetCurrentConversation(id: String?) {
        val shouldClear = id.isNullOrEmpty() || currentConversationId == id
        if (shouldClear) currentConversationId = null
        val session = stored ?: return
        stored = session.copy(
            lastConversationId = if (shouldClear) null else session.lastConversationId,
        )
        store?.save(stored!!)
    }

    private fun rememberSeen(key: String?): Boolean {
        if (key.isNullOrEmpty()) return true
        if (seen.contains(key)) return false
        seen.add(key)
        if (seen.size > 512) {
            val iterator = seen.iterator()
            repeat(64) {
                if (iterator.hasNext()) {
                    iterator.next()
                    iterator.remove()
                }
            }
        }
        return true
    }

    private fun isExpired(exp: Long): Boolean {
        val leeway = requireConfig().refreshLeewaySeconds
        val now = System.currentTimeMillis() / 1000
        return exp - now <= leeway
    }

    private fun requireConfig() = config ?: throw HermesLiveChatException(
        HermesLiveChatError.NOT_CONFIGURED,
        message = "HermesLiveChat.configure() must be called before use",
    )

    private fun requireApi() = api ?: throw HermesLiveChatException(
        HermesLiveChatError.NOT_CONFIGURED,
        message = "HermesLiveChat.configure() must be called before use",
    )
}

private class ApiClient(private val config: HermesLiveChatConfig) {
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private val http = OkHttpClient.Builder()
        .callTimeout(config.requestTimeoutMillis, TimeUnit.MILLISECONDS)
        .build()

    suspend fun publicConfig(locale: String?): JSONObject = get(
        "/api/livechat/v1/public-config",
        mapOf(
            "channel_type" to "app",
            "app_key" to config.appKey,
        ) + listOfNotNull(locale?.let { "locale" to it }).toMap(),
    )

    suspend fun init(identity: VisitorIdentity, oldToken: String?): JSONObject {
        val user = JSONObject().apply {
            putOpt("email", identity.email)
            putOpt("name", identity.name)
            putOpt("avatar", identity.avatar)
        }
        val body = JSONObject().apply {
            put("channel_type", "app")
            put("app_key", config.appKey)
            putOpt("customer_id", identity.customerId)
            putOpt("external_user_id", identity.externalUserId)
            putOpt("business_id", identity.businessId)
            putOpt("ticket_id", identity.ticketId)
            putOpt("number", identity.number)
            put("user", user)
            putOpt("locale", identity.locale)
            putOpt("identity_token", identity.identityToken)
            if (identity.attrs != null) put("attrs", JSONObject(identity.attrs))
        }
        return post("/api/livechat/v1/init", body, oldToken)
    }

    suspend fun sendText(token: String, conversationId: String?, text: String, clientMsgId: String): Message {
        val body = JSONObject().apply {
            putOpt("conversation_id", conversationId)
            put("client_msg_id", clientMsgId)
            put("content_type", "text")
            put("content", JSONObject(mapOf("text" to text)))
        }
        return Message.fromJson(messageEnvelope(post("/api/livechat/v1/messages", body, token)))
    }

    suspend fun sendImage(
        token: String,
        conversationId: String?,
        key: String,
        url: String,
        mimeType: String,
        size: Int,
        clientMsgId: String,
    ): Message {
        val body = JSONObject().apply {
            putOpt("conversation_id", conversationId)
            put("client_msg_id", clientMsgId)
            put("content_type", "image")
            put("content", JSONObject(mapOf("key" to key, "url" to url, "mime" to mimeType, "size" to size)))
        }
        return Message.fromJson(messageEnvelope(post("/api/livechat/v1/messages", body, token)))
    }

    suspend fun markRead(token: String, messageId: String) {
        post("/api/livechat/v1/messages/${encode(messageId)}/read", null, token)
    }

    suspend fun history(token: String, conversationId: String, afterId: String?, limit: Int): List<Message> {
        val json = get(
            "/api/livechat/v1/conversations/${encode(conversationId)}/messages",
            mapOf(
                "limit" to limit.toString(),
            ) + listOfNotNull(afterId?.let { "after_id" to it }).toMap(),
            token,
        )
        val items = json.optJSONArray("items") ?: JSONArray()
        return (0 until items.length()).map { Message.fromJson(items.getJSONObject(it)) }
    }

    suspend fun conversations(token: String): List<Conversation> {
        val json = get("/api/livechat/v1/conversations", mapOf("limit" to "20"), token)
        val items = json.optJSONArray("items") ?: JSONArray()
        return (0 until items.length()).map { Conversation.fromJson(items.getJSONObject(it)) }
    }

    suspend fun presign(token: String, filename: String, mimeType: String, size: Int): JSONObject = post(
        "/api/livechat/v1/attachments/presign",
        JSONObject(mapOf("filename" to filename, "mime" to mimeType, "size" to size)),
        token,
    )

    suspend fun uploadPresigned(
        url: String,
        method: String,
        headers: Map<String, String>,
        bytes: ByteArray,
        mimeType: String,
    ) = withContext(Dispatchers.IO) {
        val body = bytes.toRequestBody(mimeType.toMediaType())
        val builder = Request.Builder().url(url).method(method, body)
        headers.forEach { (key, value) -> builder.header(key, value) }
        http.newCall(builder.build()).execute().use { resp ->
            if (!resp.isSuccessful) {
                throw HermesLiveChatException(
                    HermesLiveChatError.ATTACHMENT_TYPE_INVALID,
                    message = "attachment upload failed",
                    status = resp.code,
                )
            }
        }
    }

    private suspend fun get(path: String, query: Map<String, String>, token: String? = null): JSONObject {
        val url = config.normalizedBaseUrl() + path + "?" + query.entries.joinToString("&") {
            "${encode(it.key)}=${encode(it.value)}"
        }
        val request = Request.Builder().url(url).applyHeaders(token).get().build()
        return execute(request)
    }

    private suspend fun post(path: String, body: JSONObject?, token: String?): JSONObject {
        val requestBody = body?.toString()?.toRequestBody(jsonMedia)
        val request = Request.Builder()
            .url(config.normalizedBaseUrl() + path)
            .applyHeaders(token, body != null)
            .post(requestBody ?: ByteArray(0).toRequestBody(null))
            .build()
        return execute(request)
    }

    private suspend fun execute(request: Request): JSONObject = withContext(Dispatchers.IO) {
        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            val payload = if (text.isNotEmpty()) JSONObject(text) else JSONObject()
            val code = payload.opt("code")?.toString()?.toIntOrNull()
            if (!response.isSuccessful || (code != null && code != 0)) {
                throw HermesLiveChatException(
                    error = mapBackendError(response.code, payload.optStringOrNull("code")),
                    backendCode = payload.optStringOrNull("code") ?: payload.optStringOrNull("error_code"),
                    message = payload.optStringOrNull("msg") ?: response.message,
                    status = response.code,
                )
            }
            if (payload.has("code") && payload.has("data")) {
                return@withContext payload.optJSONObject("data") ?: JSONObject()
            }
            payload
        }
    }

    private fun Request.Builder.applyHeaders(token: String?, hasBody: Boolean = false): Request.Builder {
        header("Accept", "application/json")
        if (hasBody) header("Content-Type", "application/json")
        if (token != null) header("Authorization", "Bearer $token")
        return this
    }

    private fun messageEnvelope(json: JSONObject): JSONObject = json.optJSONObject("message") ?: json
}

private class CentrifugeRealtime(
    private val emit: (HermesLiveChatEvent) -> Unit,
) {
    private var client: Client? = null

    fun connect(url: String, token: String) {
        disconnect()
        val options = Options().apply {
            setToken(token)
            setName("android")
        }
        client = Client(url, options, object : EventListener() {
            override fun onConnecting(client: Client, event: ConnectingEvent) {
                emit(HermesLiveChatEvent.ConnectionStateChanged(LiveChatConnectionState.CONNECTING))
            }

            override fun onConnected(client: Client, event: ConnectedEvent) {
                emit(HermesLiveChatEvent.ConnectionStateChanged(LiveChatConnectionState.CONNECTED))
            }

            override fun onDisconnected(client: Client, event: DisconnectedEvent) {
                emit(HermesLiveChatEvent.ConnectionStateChanged(LiveChatConnectionState.DISCONNECTED))
            }

            override fun onError(client: Client, event: ErrorEvent) {
                emit(HermesLiveChatEvent.Error(HermesLiveChatException(HermesLiveChatError.UNKNOWN, message = event.error.message)))
            }

            override fun onPublication(client: Client, event: ServerPublicationEvent) {
                val raw = String(event.data, StandardCharsets.UTF_8)
                runCatching { HermesLiveChat.handlePublication(JSONObject(raw)) }
            }
        })
        client?.connect()
    }

    fun disconnect() {
        client?.disconnect()
        client = null
        emit(HermesLiveChatEvent.ConnectionStateChanged(LiveChatConnectionState.IDLE))
    }
}

private data class StoredSession(
    val appKey: String,
    val visitorId: String,
    val contactId: Long,
    val token: String,
    val tokenExp: Long,
    val realtimeUrl: String?,
    val lastConversationId: String?,
)

private class SessionStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("hermes_livechat", Context.MODE_PRIVATE)
    private val crypto = SessionCrypto()

    fun load(appKey: String): StoredSession? {
        val encryptedKey = encryptedKey(appKey)
        prefs.getString(encryptedKey, null)?.let { raw ->
            return runCatching { parseSession(appKey, crypto.decrypt(raw)) }.getOrNull()
        }

        val legacyKey = legacyKey(appKey)
        val legacy = prefs.getString(legacyKey, null) ?: return null
        return runCatching { parseSession(appKey, legacy) }.getOrNull()?.also {
            if (saveEncrypted(it)) {
                prefs.edit().remove(legacyKey).apply()
            }
        }
    }

    fun save(session: StoredSession) {
        saveEncrypted(session)
    }

    private fun saveEncrypted(session: StoredSession): Boolean = runCatching {
        val json = JSONObject().apply {
            put("visitor_id", session.visitorId)
            put("contact_id", session.contactId)
            put("token", session.token)
            put("token_exp", session.tokenExp)
            putOpt("realtime_url", session.realtimeUrl)
            putOpt("last_conversation_id", session.lastConversationId)
        }
        prefs.edit()
            .putString(encryptedKey(session.appKey), crypto.encrypt(json.toString()))
            .remove(legacyKey(session.appKey))
            .apply()
        true
    }.getOrDefault(false)

    private fun parseSession(appKey: String, raw: String): StoredSession {
        val json = JSONObject(raw)
        return StoredSession(
            appKey = appKey,
            visitorId = json.getString("visitor_id"),
            contactId = json.getLong("contact_id"),
            token = json.getString("token"),
            tokenExp = json.getLong("token_exp"),
            realtimeUrl = json.optStringOrNull("realtime_url"),
            lastConversationId = json.optStringOrNull("last_conversation_id"),
        )
    }

    private fun legacyKey(appKey: String) = "session:$appKey"

    private fun encryptedKey(appKey: String) = "session:$appKey:v2"
}

private class SessionCrypto {
    private val alias = "hermes_livechat_session"

    fun encrypt(raw: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(raw.toByteArray(StandardCharsets.UTF_8))
        val packed = ByteArray(1 + iv.size + encrypted.size)
        packed[0] = iv.size.toByte()
        System.arraycopy(iv, 0, packed, 1, iv.size)
        System.arraycopy(encrypted, 0, packed, 1 + iv.size, encrypted.size)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun decrypt(raw: String): String {
        val packed = Base64.decode(raw, Base64.NO_WRAP)
        val ivSize = packed[0].toInt()
        val iv = packed.copyOfRange(1, 1 + ivSize)
        val encrypted = packed.copyOfRange(1 + ivSize, packed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}

private fun deriveRealtimeUrl(baseUrl: String): String {
    val trimmed = baseUrl.trimEnd('/')
    return when {
        trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://") + "/connection/websocket"
        trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://") + "/connection/websocket"
        else -> trimmed + "/connection/websocket"
    }
}

private fun HermesLiveChatConfig.normalizedBaseUrl() = baseUrl.trimEnd('/')

private fun newClientMsgId() = UUID.randomUUID().toString().replace("-", "")

private fun defaultImageFilename(mimeType: String): String =
    "image_${UUID.randomUUID().toString().replace("-", "")}.${imageExtension(mimeType)}"

private fun imageExtension(mimeType: String): String = when (mimeType.lowercase()) {
    "image/png" -> "png"
    "image/gif" -> "gif"
    else -> "jpg"
}

private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

private fun JSONObject.optStringOrNull(name: String): String? {
    if (!has(name) || isNull(name)) return null
    return optString(name).takeIf { it.isNotEmpty() }
}

private fun JSONObject.optLongOrNull(name: String): Long? {
    if (!has(name) || isNull(name)) return null
    return optLong(name)
}

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    val value = get(key)
    if (value == JSONObject.NULL) null else value
}

private fun JSONObject.toStringMap(): Map<String, String> = keys().asSequence().associateWith { key ->
    get(key).toString()
}

private fun mapBackendError(status: Int, code: String?): HermesLiveChatError = when (code) {
    "70001" -> HermesLiveChatError.BAD_REQUEST
    "70002", "LC_TOKEN_INVALID" -> HermesLiveChatError.TOKEN_INVALID
    "70003", "LC_TOKEN_EXPIRED" -> HermesLiveChatError.TOKEN_EXPIRED
    "70004", "LC_INVALID_VISITOR_ID" -> HermesLiveChatError.INVALID_VISITOR_ID
    "70024", "LC_CONV_FORBIDDEN" -> HermesLiveChatError.CONVERSATION_FORBIDDEN
    "70025", "LC_CONV_CLOSED" -> HermesLiveChatError.CONVERSATION_CLOSED
    "LC_MESSAGE_RATE_LIMITED" -> HermesLiveChatError.MESSAGE_RATE_LIMITED
    "LC_CONTENT_INVALID" -> HermesLiveChatError.CONTENT_INVALID
    "70030", "LC_ATTACHMENT_TOO_LARGE" -> HermesLiveChatError.ATTACHMENT_TOO_LARGE
    "70031", "LC_ATTACHMENT_TYPE_INVALID", "LC_ATTACHMENT_TYPE_NOT_ALLOWED" -> HermesLiveChatError.ATTACHMENT_TYPE_INVALID
    "70011", "LC_CHANNEL_DISABLED" -> HermesLiveChatError.CHANNEL_DISABLED
    "70012", "LC_DOMAIN_NOT_ALLOWED" -> HermesLiveChatError.DOMAIN_NOT_ALLOWED
    "70010", "LC_ORG_LIVECHAT_DISABLED" -> HermesLiveChatError.ORG_DISABLED
    "70006", "LC_APP_INIT_TOKEN_INVALID" -> HermesLiveChatError.APP_INIT_TOKEN_INVALID
    "70007", "LC_APP_INIT_TOKEN_EXPIRED" -> HermesLiveChatError.APP_INIT_TOKEN_EXPIRED
    "LC_REALTIME_CONNECT_UNAUTHORIZED" -> HermesLiveChatError.REALTIME_CONNECT_UNAUTHORIZED
    "70050", "LC_REALTIME_PROVIDER_UNAVAILABLE" -> HermesLiveChatError.REALTIME_PROVIDER_UNAVAILABLE
    else -> when {
        status == 400 -> HermesLiveChatError.BAD_REQUEST
        status == 401 -> HermesLiveChatError.TOKEN_INVALID
        status == 403 -> HermesLiveChatError.CONVERSATION_FORBIDDEN
        status >= 500 -> HermesLiveChatError.REALTIME_PROVIDER_UNAVAILABLE
        else -> HermesLiveChatError.UNKNOWN
    }
}
