package com.mobene.hermes.livechat.sample

import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatConfig
import com.mobene.hermes.livechat.VisitorIdentity
import com.mobene.hermes.livechat.ui.HermesLiveChatActivity
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

class MainActivity : ComponentActivity() {

    private val customConfigLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val data = result.data ?: return@registerForActivityResult
            val environment = CustomConfigActivity.extractResult(data) ?: return@registerForActivityResult
            environmentGroup.clearCheck()
            applyConfig(environment)
        }

    private lateinit var environmentGroup: RadioGroup
    private lateinit var environmentDescription: TextView
    private lateinit var baseUrlValue: TextView
    private lateinit var realtimeValue: TextView
    private lateinit var appKeyValue: TextView
    private lateinit var secretValue: TextView
    private lateinit var customerIdInput: EditText
    private lateinit var openButton: Button
    private lateinit var customButton: Button

    private var currentConfig: SampleConfig.Environment =
        SampleConfig.environments[SampleConfig.defaultEnvironmentIndex]
    private var isOpening: Boolean = false
        set(value) {
            field = value
            updateLoadingState()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "hermes-livechat"
        setContentView(buildUi())
        applyConfig(currentConfig)
    }

    private fun buildUi(): View {
        val scroll = ScrollView(this).apply {
            setBackgroundColor(0xFFF2F2F7.toInt())
            isFillViewport = true
        }

        val stack = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(28), dp(24), dp(28))
        }
        scroll.addView(
            stack,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )

        stack.addView(TextView(this).apply {
            text = "Hermes LiveChat"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(0xFF111111.toInt())
        })
        stack.addView(spacing(8))
        stack.addView(TextView(this).apply {
            text = "选择测试或生产环境即可打开客服；也可以进入自定义配置手动填写地址和 App 信息。"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(0xFF6E6E73.toInt())
        })
        stack.addView(spacing(20))

        environmentGroup = RadioGroup(this).apply {
            orientation = RadioGroup.HORIZONTAL
        }
        SampleConfig.environments.forEachIndexed { index, env ->
            val radio = RadioButton(this@MainActivity).apply {
                id = View.generateViewId()
                text = env.name
                isChecked = index == SampleConfig.defaultEnvironmentIndex
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            environmentGroup.addView(radio)
        }
        environmentGroup.setOnCheckedChangeListener { group, checkedId ->
            val index = (0 until group.childCount).firstOrNull { group.getChildAt(it).id == checkedId } ?: return@setOnCheckedChangeListener
            applyConfig(SampleConfig.environments[index])
        }

        customButton = Button(this).apply {
            text = "自定义配置"
            setOnClickListener {
                customConfigLauncher.launch(CustomConfigActivity.intent(this@MainActivity, currentConfig))
            }
        }
        environmentDescription = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(0xFF6E6E73.toInt())
        }
        stack.addView(card(title = "环境", children = listOf(environmentGroup, customButton, environmentDescription)))
        stack.addView(spacing(16))

        baseUrlValue = valueLabel()
        realtimeValue = valueLabel()
        appKeyValue = valueLabel()
        secretValue = valueLabel()
        stack.addView(card(title = "当前配置", children = listOf(
            infoRow("Base URL", baseUrlValue),
            infoRow("Realtime", realtimeValue),
            infoRow("App Key", appKeyValue),
            infoRow("Secret", secretValue),
        )))
        stack.addView(spacing(16))

        customerIdInput = EditText(this).apply {
            hint = "customerId"
            setText(SampleConfig.randomCustomerId())
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_DONE
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val randomButton = Button(this).apply {
            text = "随机生成"
            setOnClickListener { customerIdInput.setText(SampleConfig.randomCustomerId()) }
        }
        val customerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(customerIdInput)
            addView(spacing(width = 8, height = 0))
            addView(randomButton)
        }
        stack.addView(card(title = "访客", children = listOf(customerRow)))
        stack.addView(spacing(24))

        openButton = Button(this).apply {
            text = "打开客服"
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = roundedFill(0xFF007AFF.toInt(), radiusDp = 10)
            setPadding(dp(18), dp(14), dp(18), dp(14))
            minHeight = dp(50)
            setOnClickListener { openLiveChat() }
        }
        stack.addView(openButton)

        return scroll
    }

    private fun applyConfig(config: SampleConfig.Environment) {
        currentConfig = config
        environmentDescription.text = "${config.name} · ${config.description}"
        baseUrlValue.text = config.baseUrl
        realtimeValue.text = if (config.realtimeUrl.isEmpty()) "自动推导" else config.realtimeUrl
        appKeyValue.text = config.appKey
        secretValue.text = maskSecret(config.secretKey)
    }

    private fun updateLoadingState() {
        openButton.isEnabled = !isOpening
        customButton.isEnabled = !isOpening
        environmentGroup.isEnabled = !isOpening
        (0 until environmentGroup.childCount).forEach {
            environmentGroup.getChildAt(it).isEnabled = !isOpening
        }
        openButton.alpha = if (isOpening) 0.7f else 1f
        openButton.text = if (isOpening) "正在打开..." else "打开客服"
    }

    private fun openLiveChat() {
        if (isOpening) return
        currentFocus?.clearFocus()

        val baseUrl = currentConfig.baseUrl.trim().trimEnd('/')
        val realtimeUrl = currentConfig.realtimeUrl.trim()
        val appKey = currentConfig.appKey.trim()
        val secret = currentConfig.secretKey.trim()
        val typed = customerIdInput.text.toString().trim()
        val customerId = typed.ifEmpty { SampleConfig.randomCustomerId() }
        if (typed.isEmpty()) customerIdInput.setText(customerId)

        if (!baseUrl.startsWith("http")) {
            showError("Base URL 需要是有效的 http:// 或 https:// 地址")
            return
        }
        if (appKey.isEmpty()) {
            showError("App Key 不能为空")
            return
        }
        if (realtimeUrl.isNotEmpty() && !realtimeUrl.startsWith("ws")) {
            showError("Realtime URL 需要是有效的 ws:// 或 wss:// 地址")
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

        isOpening = true
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
        // HermesLiveChatActivity does not return a result; clear loading state when we resume.
        window.decorView.post { isOpening = false }
    }

    override fun onResume() {
        super.onResume()
        if (isOpening) isOpening = false
    }

    // -- helpers --------------------------------------------------------------

    private fun card(title: String, children: List<View>): View {
        val titleLabel = TextView(this).apply {
            text = title
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(0xFF111111.toInt())
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        content.addView(titleLabel)
        content.addView(spacing(10))
        children.forEachIndexed { index, child ->
            if (child.parent is ViewGroup) (child.parent as ViewGroup).removeView(child)
            content.addView(child)
            if (index != children.lastIndex) content.addView(spacing(12))
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = roundedFill(Color.WHITE, radiusDp = 10)
            setPadding(dp(16), dp(14), dp(16), dp(14))
            addView(content)
        }
    }

    private fun infoRow(title: String, valueLabel: TextView): View {
        val titleView = TextView(this).apply {
            text = title
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(0xFF6E6E73.toInt())
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(titleView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(spacing(width = 12, height = 0))
            valueLabel.layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                gravity = Gravity.END
            }
            valueLabel.gravity = Gravity.END
            addView(valueLabel)
        }
    }

    private fun valueLabel(): TextView = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTextColor(0xFF111111.toInt())
    }

    private fun spacing(height: Int = 0, width: Int = 0): View {
        return View(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                if (width == 0) ViewGroup.LayoutParams.MATCH_PARENT else dp(width),
                if (height == 0) dp(0) else dp(height),
            )
        }
    }

    private fun roundedFill(color: Int, radiusDp: Int): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(radiusDp).toFloat()
            setColor(color)
        }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun maskSecret(value: String): String {
        if (value.isEmpty()) return "-"
        if (value.length <= 10) return value
        return "${value.take(6)}...${value.takeLast(4)}"
    }

    private fun showError(message: String) {
        AlertDialog.Builder(this)
            .setTitle("配置错误")
            .setMessage(message)
            .setPositiveButton("确定", null)
            .show()
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
}
