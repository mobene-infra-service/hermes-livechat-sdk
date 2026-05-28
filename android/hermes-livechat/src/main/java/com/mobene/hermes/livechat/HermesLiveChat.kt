package com.mobene.hermes.livechat

import android.content.Context
import com.mobene.hermes.livechat.internal.ApiClient
import com.mobene.hermes.livechat.internal.CentrifugeRealtime
import com.mobene.hermes.livechat.internal.SessionStore
import com.mobene.hermes.livechat.internal.StoredSession
import com.mobene.hermes.livechat.internal.defaultImageFilename
import com.mobene.hermes.livechat.internal.newClientMsgId
import com.mobene.hermes.livechat.internal.optStringOrNull
import com.mobene.hermes.livechat.internal.toStringMap
import com.mobene.hermes.livechat.internal.toVisitorSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

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

    val connectionState: LiveChatConnectionState
        get() = realtimeState

    fun configure(context: Context, config: HermesLiveChatConfig) {
        disconnectRealtime()
        this.config = config
        api = ApiClient(config)
        store = SessionStore(context.applicationContext)
        realtime = CentrifugeRealtime(
            emit = { emitRealtimeEvent(it) },
            onPublication = { handlePublication(it) },
        )
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
        val cached = stored ?: store?.load(cfg.appKey)
        currentConversationId = currentConversationId ?: cached?.lastConversationId
        if (cached != null && !isExpired(cached.tokenExp)) {
            stored = cached
            connectRealtime(cached.realtimeUrl ?: cfg.realtimeUrl, cached.token)
            return cached.toVisitorSession(cfg.realtimeUrl)
        }

        val next = renewSession(identity, cached?.token)
        refreshCurrentConversation(next.token)
        connectRealtime(next.realtimeUrl ?: cfg.realtimeUrl, next.token)
        return next.toVisitorSession(cfg.realtimeUrl)
    }

    suspend fun sendText(text: String, conversationId: String? = null): Message =
        sendTextResult(text, conversationId).message

    suspend fun sendTextMessages(text: String, conversationId: String? = null): List<Message> =
        sendTextResult(text, conversationId).messages

    private suspend fun sendTextResult(text: String, conversationId: String? = null): SendMessageResult {
        val token = validToken()
        val clientMsgId = newClientMsgId()
        ensureRealtimeConnected(token)
        return handleSendResult(
            retryOnConversationClosed(conversationId) { convId ->
                requireApi().sendText(token, convId, text, clientMsgId)
            }
        )
    }

    suspend fun sendImage(
        bytes: ByteArray,
        mimeType: String,
        filename: String? = null,
        conversationId: String? = null,
    ): Message = sendImageResult(bytes, mimeType, filename, conversationId).message

    suspend fun sendImageMessages(
        bytes: ByteArray,
        mimeType: String,
        filename: String? = null,
        conversationId: String? = null,
    ): List<Message> = sendImageResult(bytes, mimeType, filename, conversationId).messages

    private suspend fun sendImageResult(
        bytes: ByteArray,
        mimeType: String,
        filename: String? = null,
        conversationId: String? = null,
    ): SendMessageResult {
        val token = validToken()
        val presign = requireApi().presign(token, filename ?: defaultImageFilename(mimeType), mimeType, bytes.size)
        requireApi().uploadPresigned(
            url = presign.getString("upload_url"),
            method = presign.optString("method", "PUT"),
            headers = presign.optJSONObject("headers")?.toStringMap().orEmpty(),
            bytes = bytes,
            mimeType = mimeType,
        )
        val key = presign.getString("key")
        val downloadUrl = presign.getString("download_url")
        val clientMsgId = newClientMsgId()
        ensureRealtimeConnected(token)
        return handleSendResult(
            retryOnConversationClosed(conversationId) { convId ->
                requireApi().sendImage(token, convId, key, downloadUrl, mimeType, bytes.size, clientMsgId)
            }
        )
    }

    // retryOnConversationClosed runs `send` once with the caller-supplied (or
    // remembered) conversation id; if the backend reports CONVERSATION_CLOSED
    // and the caller did NOT pin a specific conversation, the stale pointer is
    // dropped and the request retried with conversation_id=null so the server
    // allocates a fresh one.
    private suspend inline fun retryOnConversationClosed(
        explicitConversationId: String?,
        send: (conversationId: String?) -> SendMessageResult,
    ): SendMessageResult {
        val implicit = explicitConversationId == null
        val convId = explicitConversationId ?: currentConversationId
        return try {
            send(convId)
        } catch (error: HermesLiveChatException) {
            if (!implicit || error.error != HermesLiveChatError.CONVERSATION_CLOSED) throw error
            forgetCurrentConversation(convId)
            send(null)
        }
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

    private fun handleSendResult(result: SendMessageResult): SendMessageResult {
        val conversation = result.conversation
        if (conversation != null) {
            rememberConversation(conversation.uuid)
        }
        for (message in result.messages) {
            rememberSeen(message.uuid)
            rememberSeen(message.clientMsgId)
            if (message.uuid == result.message.uuid || message.clientMsgId == result.message.clientMsgId) continue
            if (conversation != null) {
                _events.tryEmit(HermesLiveChatEvent.MessageReceived(message, conversation))
            }
        }
        rememberConversation(result.message.conversationId)
        rememberSeen(result.message.uuid)
        rememberSeen(result.message.clientMsgId)
        touchRealtimeActivity()
        return result
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

    private fun handlePublication(payload: JSONObject) {
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

        val next = renewSession(VisitorIdentity(), session.token, session.realtimeUrl)
        refreshCurrentConversation(next.token)
        connectRealtime(next.realtimeUrl ?: cfg.realtimeUrl, next.token)
        return next.token
    }

    // renewSession calls /init (with `oldToken` for renewal semantics), persists
    // the result, and returns the new StoredSession. Both startSession and
    // validToken share this — formerly each had its own copy of the JSON-extract
    // + store.save block.
    private suspend fun renewSession(
        identity: VisitorIdentity,
        oldToken: String?,
        fallbackRealtimeUrl: String? = null,
    ): StoredSession {
        val cfg = requireConfig()
        val json = requireApi().init(identity, oldToken)
        val realtimeUrl = json.optJSONObject("realtime")?.optString("url")?.takeIf { it.isNotEmpty() }
            ?: fallbackRealtimeUrl
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
        return next
    }

    private suspend fun refreshCurrentConversation(token: String) {
        runCatching {
            requireApi().conversations(token)
                .firstOrNull { it.status != "closed" }
                ?.let { rememberConversation(it.uuid) }
        }
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
