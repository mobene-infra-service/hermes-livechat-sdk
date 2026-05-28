package com.mobene.hermes.livechat

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
