package com.mobene.hermes.livechat.sample

import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatConfig
import com.mobene.hermes.livechat.VisitorIdentity
import com.mobene.hermes.livechat.ui.HermesLiveChatActivity

class MainActivity : ComponentActivity() {
    private lateinit var baseUrlInput: EditText
    private lateinit var realtimeUrlInput: EditText
    private lateinit var appKeyInput: EditText
    private lateinit var customerIdInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "hermes-livechat"
        buildUi()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(32, 48, 32, 32)
        }

        root.addView(TextView(this).apply {
            text = "hermes-livechat"
            textSize = 22f
            gravity = Gravity.CENTER
        })

        baseUrlInput = field(
            hint = "baseUrl",
            value = DEFAULT_BASE_URL,
            inputType = InputType.TYPE_TEXT_VARIATION_URI,
        )
        realtimeUrlInput = field(
            hint = "realtimeUrl（留空由 SDK 从 baseUrl 自动推导）",
            value = DEFAULT_REALTIME_URL,
            inputType = InputType.TYPE_TEXT_VARIATION_URI,
        )
        appKeyInput = field(
            hint = "appKey",
            value = DEFAULT_APP_KEY,
        )
        customerIdInput = field(
            hint = "customerId",
            value = "android-test-user",
            imeOption = EditorInfo.IME_ACTION_DONE,
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

    private fun field(
        hint: String,
        value: String,
        inputType: Int = InputType.TYPE_CLASS_TEXT,
        imeOption: Int = EditorInfo.IME_ACTION_NEXT,
    ): EditText {
        return EditText(this).apply {
            this.hint = hint
            setText(value)
            setSingleLine(true)
            this.inputType = inputType
            imeOptions = imeOption
        }
    }

    private fun openLiveChat() {
        val baseUrl = baseUrlInput.text.toString().trim().trimEnd('/')
        val realtimeUrl = realtimeUrlInput.text.toString().trim()
        val appKey = appKeyInput.text.toString().trim()
        val customerId = customerIdInput.text.toString().trim().ifEmpty { "android-test-user" }

        if (baseUrl.isEmpty() || !baseUrl.startsWith("http")) {
            showError("请填写有效的 baseUrl（以 http:// 或 https:// 开头）")
            return
        }
        if (appKey.isEmpty()) {
            showError("请填写 appKey")
            return
        }
        if (realtimeUrl.isNotEmpty() && !realtimeUrl.startsWith("ws")) {
            showError("realtimeUrl 必须以 ws:// 或 wss:// 开头")
            return
        }

        val config = if (realtimeUrl.isEmpty()) {
            HermesLiveChatConfig(baseUrl = baseUrl, appKey = appKey)
        } else {
            HermesLiveChatConfig(baseUrl = baseUrl, appKey = appKey, realtimeUrl = realtimeUrl)
        }
        HermesLiveChat.configure(context = applicationContext, config = config)

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

    private fun showError(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val DEFAULT_BASE_URL = "https://hermes-test.financifyx.com/api"
        private const val DEFAULT_REALTIME_URL = "wss://hermes-test.financifyx.com/api/connection/websocket"
        private const val DEFAULT_APP_KEY = "019e5ed46ccb74cf885dd5bbecf3bde7"
    }
}
