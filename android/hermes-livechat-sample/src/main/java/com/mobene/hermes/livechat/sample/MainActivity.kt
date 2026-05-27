package com.mobene.hermes.livechat.sample

import android.os.Bundle
import android.text.InputType
import android.util.Base64
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
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private lateinit var baseUrlInput: EditText
    private lateinit var realtimeUrlInput: EditText
    private lateinit var appKeyInput: EditText
    private lateinit var secretInput: EditText
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
        secretInput = field(
            hint = "secretKey（仅调试签 identity_token）",
            value = DEFAULT_SECRET_KEY,
        )
        customerIdInput = field(
            hint = "customerId",
            value = "android-test-user",
            imeOption = EditorInfo.IME_ACTION_DONE,
        )

        root.addView(baseUrlInput)
        root.addView(realtimeUrlInput)
        root.addView(appKeyInput)
        root.addView(secretInput)
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
        val secret = secretInput.text.toString().trim()
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

        val identityToken = try {
            secret.takeIf { it.isNotEmpty() }?.let {
                signIdentityToken(secret = it, appKey = appKey, customerId = customerId, name = "Android Test")
            }
        } catch (error: Exception) {
            showError("identity_token 生成失败：${error.message ?: "unknown"}")
            return
        }

        HermesLiveChatActivity.open(
            context = this,
            identity = VisitorIdentity(
                customerId = customerId,
                name = "Android Test",
                locale = "zh-CN",
                identityToken = identityToken,
            ),
            startSessionOnOpen = true,
        )
    }

    private fun signIdentityToken(secret: String, appKey: String, customerId: String, name: String): String {
        val now = System.currentTimeMillis() / 1000
        val header = JSONObject(mapOf("alg" to "HS256", "typ" to "JWT"))
        val payload = JSONObject().apply {
            put("aud", "livechat:init")
            put("app_key", appKey)
            put("sub", customerId)
            put("customer_id", customerId)
            put("name", name)
            put("locale", "zh-CN")
            put("iat", now)
            put("exp", now + 5 * 60)
        }
        val signingInput = "${base64Url(header.toString())}.${base64Url(payload.toString())}"
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return "$signingInput.${base64Url(mac.doFinal(signingInput.toByteArray(Charsets.UTF_8)))}"
    }

    private fun base64Url(value: String): String = base64Url(value.toByteArray(Charsets.UTF_8))

    private fun base64Url(value: ByteArray): String =
        Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun showError(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val DEFAULT_BASE_URL = "https://hermes-test.financifyx.com/api"
        private const val DEFAULT_REALTIME_URL = "wss://hermes-test.financifyx.com/api/connection/websocket"
        private const val DEFAULT_APP_KEY = "app_019e5ed46ccb74cf885dd5bbecf3bde7"
        private const val DEFAULT_SECRET_KEY = "sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0"
    }
}
