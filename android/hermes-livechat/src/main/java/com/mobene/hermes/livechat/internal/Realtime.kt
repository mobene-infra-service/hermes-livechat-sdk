package com.mobene.hermes.livechat.internal

import com.mobene.hermes.livechat.HermesLiveChatError
import com.mobene.hermes.livechat.HermesLiveChatEvent
import com.mobene.hermes.livechat.HermesLiveChatException
import com.mobene.hermes.livechat.LiveChatConnectionState
import io.github.centrifugal.centrifuge.Client
import io.github.centrifugal.centrifuge.ConnectedEvent
import io.github.centrifugal.centrifuge.ConnectingEvent
import io.github.centrifugal.centrifuge.DisconnectedEvent
import io.github.centrifugal.centrifuge.ErrorEvent
import io.github.centrifugal.centrifuge.EventListener
import io.github.centrifugal.centrifuge.Options
import io.github.centrifugal.centrifuge.ServerPublicationEvent
import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal class CentrifugeRealtime(
    private val emit: (HermesLiveChatEvent) -> Unit,
    private val onPublication: (JSONObject) -> Unit,
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
                runCatching { onPublication(JSONObject(raw)) }
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
