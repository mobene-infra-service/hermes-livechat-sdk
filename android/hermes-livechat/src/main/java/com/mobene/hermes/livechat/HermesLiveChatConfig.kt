package com.mobene.hermes.livechat

data class HermesLiveChatConfig(
    val baseUrl: String,
    val appKey: String,
    val realtimeUrl: String = deriveRealtimeUrl(baseUrl),
    val refreshLeewaySeconds: Long = 60,
    val requestTimeoutMillis: Long = 10_000,
    val realtimeIdleDisconnectMillis: Long = 5 * 60 * 1000L,
)

private fun deriveRealtimeUrl(baseUrl: String): String {
    val trimmed = baseUrl.trimEnd('/')
    return when {
        trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://") + "/connection/websocket"
        trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://") + "/connection/websocket"
        else -> trimmed + "/connection/websocket"
    }
}

internal fun HermesLiveChatConfig.normalizedBaseUrl() = baseUrl.trimEnd('/')
