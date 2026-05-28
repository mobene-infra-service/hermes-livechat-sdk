package com.mobene.hermes.livechat.internal

import com.mobene.hermes.livechat.Conversation
import com.mobene.hermes.livechat.HermesLiveChatConfig
import com.mobene.hermes.livechat.HermesLiveChatError
import com.mobene.hermes.livechat.HermesLiveChatException
import com.mobene.hermes.livechat.Message
import com.mobene.hermes.livechat.SendMessageResult
import com.mobene.hermes.livechat.VisitorIdentity
import com.mobene.hermes.livechat.normalizedBaseUrl
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

internal class ApiClient(private val config: HermesLiveChatConfig) {
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

    suspend fun sendText(token: String, conversationId: String?, text: String, clientMsgId: String): SendMessageResult {
        val body = JSONObject().apply {
            putOpt("conversation_id", conversationId)
            put("client_msg_id", clientMsgId)
            put("content_type", "text")
            put("content", JSONObject(mapOf("text" to text)))
        }
        return SendMessageResult.fromJson(post("/api/livechat/v1/messages", body, token))
    }

    suspend fun sendImage(
        token: String,
        conversationId: String?,
        key: String,
        url: String,
        mimeType: String,
        size: Int,
        clientMsgId: String,
    ): SendMessageResult {
        val body = JSONObject().apply {
            putOpt("conversation_id", conversationId)
            put("client_msg_id", clientMsgId)
            put("content_type", "image")
            put("content", JSONObject(mapOf("key" to key, "url" to url, "mime" to mimeType, "size" to size)))
        }
        return SendMessageResult.fromJson(post("/api/livechat/v1/messages", body, token))
    }

    suspend fun markRead(token: String, messageId: String) {
        post("/api/livechat/v1/messages/${urlEncode(messageId)}/read", null, token)
    }

    suspend fun history(token: String, conversationId: String, afterId: String?, limit: Int): List<Message> {
        val json = get(
            "/api/livechat/v1/conversations/${urlEncode(conversationId)}/messages",
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
            "${urlEncode(it.key)}=${urlEncode(it.value)}"
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
}

internal fun mapBackendError(status: Int, code: String?): HermesLiveChatError = when (code) {
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
