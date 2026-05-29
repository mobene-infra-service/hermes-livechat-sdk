package com.mobene.hermes.livechat.sample

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity

class CustomConfigActivity : ComponentActivity() {

    private lateinit var baseUrlInput: EditText
    private lateinit var realtimeUrlInput: EditText
    private lateinit var appKeyInput: EditText
    private lateinit var secretInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "自定义配置"
        setContentView(buildUi())

        intent.getStringExtra(EXTRA_BASE_URL)?.let { baseUrlInput.setText(it) }
        intent.getStringExtra(EXTRA_REALTIME_URL)?.let { realtimeUrlInput.setText(it) }
        intent.getStringExtra(EXTRA_APP_KEY)?.let { appKeyInput.setText(it) }
        intent.getStringExtra(EXTRA_SECRET)?.let { secretInput.setText(it) }
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

        baseUrlInput = field("Base URL", InputType.TYPE_TEXT_VARIATION_URI)
        realtimeUrlInput = field("Realtime URL（可留空自动推导）", InputType.TYPE_TEXT_VARIATION_URI)
        appKeyInput = field("App Key", InputType.TYPE_CLASS_TEXT)
        secretInput = field("Secret Key（可留空）", InputType.TYPE_CLASS_TEXT)

        stack.addView(labeled("Base URL", baseUrlInput))
        stack.addView(spacing(14))
        stack.addView(labeled("Realtime URL", realtimeUrlInput))
        stack.addView(spacing(14))
        stack.addView(labeled("App Key", appKeyInput))
        stack.addView(spacing(14))
        stack.addView(labeled("Secret Key", secretInput))
        stack.addView(spacing(24))

        val saveButton = Button(this).apply {
            text = "保存并使用"
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(10).toFloat()
                setColor(0xFF007AFF.toInt())
            }
            setPadding(dp(18), dp(14), dp(18), dp(14))
            minHeight = dp(50)
            setOnClickListener { onSave() }
        }
        stack.addView(saveButton)

        return scroll
    }

    private fun field(hint: String, inputType: Int): EditText {
        return EditText(this).apply {
            this.hint = hint
            setSingleLine(true)
            this.inputType = inputType
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
    }

    private fun labeled(title: String, field: EditText): View {
        val label = TextView(this).apply {
            text = title
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(typeface, Typeface.BOLD)
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label)
            addView(spacing(8))
            addView(field)
        }
    }

    private fun onSave() {
        val baseUrl = baseUrlInput.text.toString().trim().trimEnd('/')
        val realtimeUrl = realtimeUrlInput.text.toString().trim()
        val appKey = appKeyInput.text.toString().trim()
        val secret = secretInput.text.toString().trim()

        if (!baseUrl.startsWith("http")) {
            error("Base URL 需要是有效的 http:// 或 https:// 地址")
            return
        }
        if (realtimeUrl.isNotEmpty() && !realtimeUrl.startsWith("ws")) {
            error("Realtime URL 需要是有效的 ws:// 或 wss:// 地址")
            return
        }
        if (appKey.isEmpty()) {
            error("App Key 不能为空")
            return
        }

        val data = Intent().apply {
            putExtra(EXTRA_NAME, "自定义")
            putExtra(EXTRA_DESCRIPTION, baseUrl)
            putExtra(EXTRA_BASE_URL, baseUrl)
            putExtra(EXTRA_REALTIME_URL, realtimeUrl)
            putExtra(EXTRA_APP_KEY, appKey)
            putExtra(EXTRA_SECRET, secret)
        }
        setResult(RESULT_OK, data)
        finish()
    }

    private fun error(message: String) {
        AlertDialog.Builder(this)
            .setTitle("配置错误")
            .setMessage(message)
            .setPositiveButton("确定", null)
            .show()
    }

    private fun spacing(height: Int): View = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(height))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_NAME = "name"
        private const val EXTRA_DESCRIPTION = "description"
        private const val EXTRA_BASE_URL = "baseUrl"
        private const val EXTRA_REALTIME_URL = "realtimeUrl"
        private const val EXTRA_APP_KEY = "appKey"
        private const val EXTRA_SECRET = "secret"

        fun intent(context: Context, prefill: SampleConfig.Environment): Intent =
            Intent(context, CustomConfigActivity::class.java).apply {
                putExtra(EXTRA_BASE_URL, prefill.baseUrl)
                putExtra(EXTRA_REALTIME_URL, prefill.realtimeUrl)
                putExtra(EXTRA_APP_KEY, prefill.appKey)
                putExtra(EXTRA_SECRET, prefill.secretKey)
            }

        fun extractResult(data: Intent): SampleConfig.Environment? {
            val baseUrl = data.getStringExtra(EXTRA_BASE_URL) ?: return null
            return SampleConfig.Environment(
                name = data.getStringExtra(EXTRA_NAME) ?: "自定义",
                description = data.getStringExtra(EXTRA_DESCRIPTION) ?: baseUrl,
                baseUrl = baseUrl,
                realtimeUrl = data.getStringExtra(EXTRA_REALTIME_URL).orEmpty(),
                appKey = data.getStringExtra(EXTRA_APP_KEY).orEmpty(),
                secretKey = data.getStringExtra(EXTRA_SECRET).orEmpty(),
            )
        }
    }
}
