package com.mobene.hermes.livechat.sample

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatConfig
import com.mobene.hermes.livechat.VisitorIdentity
import com.mobene.hermes.livechat.ui.HermesLiveChatActivity

class MainActivity : Activity() {
    private lateinit var baseUrlInput: EditText
    private lateinit var realtimeUrlInput: EditText
    private lateinit var appKeyInput: EditText
    private lateinit var customerIdInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Hermes LiveChat Test"
        buildUi()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(32, 48, 32, 32)
        }

        root.addView(TextView(this).apply {
            text = "Hermes LiveChat Test"
            textSize = 22f
            gravity = Gravity.CENTER
        })

        baseUrlInput = field(
            hint = "baseUrl",
            value = DEFAULT_BASE_URL,
        )
        realtimeUrlInput = field(
            hint = "realtimeUrl",
            value = DEFAULT_REALTIME_URL,
        )
        appKeyInput = field(
            hint = "appKey",
            value = DEFAULT_APP_KEY,
        )
        customerIdInput = field(
            hint = "customerId",
            value = "android-test-user",
        )

        root.addView(baseUrlInput)
        root.addView(realtimeUrlInput)
        root.addView(appKeyInput)
        root.addView(customerIdInput)
        root.addView(Button(this).apply {
            text = "打开客服"
            setOnClickListener { openLiveChat() }
        })

        setContentView(root)
    }

    private fun field(hint: String, value: String): EditText {
        return EditText(this).apply {
            this.hint = hint
            setText(value)
            setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
    }

    private fun openLiveChat() {
        val baseUrl = baseUrlInput.text.toString().trim().trimEnd('/')
        val realtimeUrl = realtimeUrlInput.text.toString().trim().ifEmpty { DEFAULT_REALTIME_URL }
        val appKey = appKeyInput.text.toString().trim()
        val customerId = customerIdInput.text.toString().trim().ifEmpty { "android-test-user" }

        HermesLiveChat.configure(
            context = applicationContext,
            config = HermesLiveChatConfig(
                baseUrl = baseUrl,
                appKey = appKey,
                realtimeUrl = realtimeUrl,
            ),
        )

        HermesLiveChatActivity.open(
            context = this,
            identity = VisitorIdentity(
                customerId = customerId,
                name = "Android Test",
                locale = "zh-CN",
            ),
            startSessionOnOpen = true,
        )
    }

    companion object {
        private const val DEFAULT_BASE_URL = "https://hermes-test.financifyx.com/api"
        private const val DEFAULT_REALTIME_URL = "wss://hermes-test.financifyx.com/api/connection/websocket"
        private const val DEFAULT_APP_KEY = "app_019e5ed46ccb74cf885dd5bbecf3bde7"
    }
}
