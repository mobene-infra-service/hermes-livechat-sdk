package com.mobene.hermes.livechat.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatEvent
import com.mobene.hermes.livechat.LiveChatConnectionState
import com.mobene.hermes.livechat.Message
import com.mobene.hermes.livechat.VisitorIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.max

class HermesLiveChatActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var identity: VisitorIdentity
    private lateinit var messages: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText
    private lateinit var status: TextView
    private lateinit var composer: LinearLayout
    private var started = false
    private var eventsJob: Job? = null
    private val messageKeys = mutableSetOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        identity = VisitorIdentity.fromJson(intent.getStringExtra(EXTRA_IDENTITY).orEmpty())
        title = intent.getStringExtra(EXTRA_TITLE) ?: "在线客服"
        configureWindow()
        buildUi()
        subscribeEvents()
        loadWelcome()
        if (intent.getBooleanExtra(EXTRA_START_ON_OPEN, false)) {
            ensureSession()
        }
    }

    override fun onDestroy() {
        eventsJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun configureWindow() {
        window.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = SCREEN_BACKGROUND
            window.navigationBarColor = SCREEN_BACKGROUND
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        }
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(SCREEN_BACKGROUND)
        }
        root.addView(buildHeader(), LinearLayout.LayoutParams.MATCH_PARENT, dp(56))

        scroll = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
            setPadding(0, dp(6), 0, dp(8))
        }
        messages = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        scroll.addView(
            messages,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        root.addView(
            scroll,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        composer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            setPadding(dp(16), dp(10), dp(16), dp(10))
            setBackgroundColor(Color.WHITE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(8).toFloat()
            }
        }
        input = EditText(this).apply {
            hint = "输入消息"
            textSize = 15f
            setTextColor(TEXT_PRIMARY)
            setHintTextColor(TEXT_MUTED)
            background = rounded(
                color = Color.WHITE,
                strokeColor = BORDER,
                strokeWidth = dp(1),
                radius = dp(20).toFloat(),
            )
            setPadding(dp(16), dp(9), dp(16), dp(9))
            minHeight = dp(42)
            setSingleLine(false)
            maxLines = 4
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_SEND) {
                    sendText()
                    true
                } else {
                    false
                }
            }
        }
        val send = Button(this).apply {
            text = "发送"
            textSize = 14f
            setTextColor(Color.WHITE)
            minWidth = dp(64)
            minHeight = dp(42)
            minimumHeight = 0
            minimumWidth = 0
            background = rounded(PRIMARY, radius = dp(20).toFloat())
            setOnClickListener { sendText() }
        }
        composer.addView(
            input,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(10)
            },
        )
        composer.addView(send, LinearLayout.LayoutParams(dp(64), dp(42)))
        root.addView(composer, LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        setContentView(root)
        applyInsets(root)
        status.tag = "status"
    }

    private fun buildHeader(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(16), 0)
            setBackgroundColor(Color.WHITE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(2).toFloat()
            }

            addView(TextView(this@HermesLiveChatActivity).apply {
                text = "‹"
                textSize = 32f
                gravity = Gravity.CENTER
                setTextColor(TEXT_PRIMARY)
                setOnClickListener { finish() }
            }, LinearLayout.LayoutParams(dp(44), LinearLayout.LayoutParams.MATCH_PARENT))

            addView(TextView(this@HermesLiveChatActivity).apply {
                text = title?.toString().orEmpty().ifBlank { "在线客服" }
                textSize = 17f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(TEXT_PRIMARY)
                gravity = Gravity.CENTER_VERTICAL
                maxLines = 1
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))

            status = TextView(this@HermesLiveChatActivity).apply {
                text = "未连接"
                textSize = 12f
                setTextColor(TEXT_SECONDARY)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                background = rounded(SURFACE_MUTED, radius = dp(14).toFloat())
                gravity = Gravity.CENTER
            }
            addView(status, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(28)))
        }
    }

    private fun applyInsets(root: LinearLayout) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        val baseComposerLeft = composer.paddingLeft
        val baseComposerTop = composer.paddingTop
        val baseComposerRight = composer.paddingRight
        val baseComposerBottom = composer.paddingBottom

        root.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            val ime = insets.getInsets(WindowInsets.Type.ime())
            root.setPadding(bars.left, bars.top, bars.right, 0)
            composer.setPadding(
                baseComposerLeft,
                baseComposerTop,
                baseComposerRight,
                baseComposerBottom + max(bars.bottom, ime.bottom),
            )
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
            insets
        }
        root.requestApplyInsets()
    }

    private fun subscribeEvents() {
        eventsJob = scope.launch {
            HermesLiveChat.events.collect { event ->
                when (event) {
                    is HermesLiveChatEvent.ConnectionStateChanged -> status.text = event.state.label()
                    is HermesLiveChatEvent.MessageReceived -> addMessage(event.message)
                    is HermesLiveChatEvent.ConversationUpdated -> {
                        if (event.conversation.status == "closed") input.isEnabled = false
                    }
                    is HermesLiveChatEvent.MessageRead -> Unit
                    is HermesLiveChatEvent.Error -> addSystemMessage(event.error.message ?: event.error.error.name)
                }
            }
        }
    }

    private fun loadWelcome() {
        scope.launch {
            runCatching {
                HermesLiveChat.prefetchWelcome(intent.getStringExtra(EXTRA_LOCALE))
            }.onSuccess {
                if (it.isNotBlank()) addSystemMessage(it)
            }.onFailure {
                addSystemMessage(it.message ?: "加载欢迎语失败")
            }
        }
    }

    private fun ensureSession() {
        if (started) return
        scope.launch {
            runCatching {
                HermesLiveChat.startSession(identity)
            }.onSuccess {
                started = true
                HermesLiveChat.currentConversationId?.let { conversationId ->
                    HermesLiveChat.history(conversationId).forEach(::addMessage)
                }
            }.onFailure {
                addSystemMessage(it.message ?: "初始化会话失败")
            }
        }
    }

    private fun sendText() {
        val text = input.text.toString().trim()
        if (text.isEmpty()) return
        input.setText("")
        scope.launch {
            runCatching {
                if (!started) {
                    HermesLiveChat.startSession(identity)
                    started = true
                }
                HermesLiveChat.sendText(text)
            }.onSuccess(::addMessage).onFailure {
                input.setText(text)
                addSystemMessage(it.message ?: "发送失败")
            }
        }
    }

    private fun addSystemMessage(text: String) {
        addBubble(text, mine = false)
    }

    private fun addMessage(message: Message) {
        val key = messageKey(message)
        if (key != null && !messageKeys.add(key)) return

        val text = when (message.contentType) {
            "text" -> message.content.optString("text")
            "image" -> message.content.optString("url")
            else -> "[${message.contentType}]"
        }
        addBubble(text, mine = message.senderType == "visitor")
    }

    private fun messageKey(message: Message): String? {
        return message.uuid.takeIf { it.isNotBlank() }
            ?: message.clientMsgId.takeIf { it.isNotBlank() }
    }

    private fun addBubble(text: String, mine: Boolean) {
        val row = LinearLayout(this).apply {
            gravity = if (mine) Gravity.END else Gravity.START
            setPadding(dp(16), dp(4), dp(16), dp(4))
        }
        val bubble = TextView(this).apply {
            this.text = text
            textSize = 15f
            setTextColor(if (mine) Color.WHITE else TEXT_PRIMARY)
            setLineSpacing(dp(2).toFloat(), 1.0f)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            maxWidth = (resources.displayMetrics.widthPixels * 0.78f).toInt()
            background = rounded(
                color = if (mine) PRIMARY else Color.WHITE,
                strokeColor = if (mine) PRIMARY else BORDER,
                strokeWidth = if (mine) 0 else dp(1),
                radius = dp(16).toFloat(),
            )
        }
        row.addView(bubble)
        messages.addView(row)
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun LiveChatConnectionState.label(): String = when (this) {
        LiveChatConnectionState.IDLE -> "未连接"
        LiveChatConnectionState.CONNECTING -> "连接中"
        LiveChatConnectionState.CONNECTED -> "已连接"
        LiveChatConnectionState.DISCONNECTED -> "已断开"
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun rounded(
        color: Int,
        strokeColor: Int? = null,
        strokeWidth: Int = 0,
        radius: Float,
    ): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(color)
        cornerRadius = radius
        if (strokeColor != null && strokeWidth > 0) {
            setStroke(strokeWidth, strokeColor)
        }
    }

    companion object {
        private val SCREEN_BACKGROUND = Color.parseColor("#F5F7FB")
        private val SURFACE_MUTED = Color.parseColor("#F1F5F9")
        private val BORDER = Color.parseColor("#E2E8F0")
        private val PRIMARY = Color.parseColor("#2563EB")
        private val TEXT_PRIMARY = Color.parseColor("#111827")
        private val TEXT_SECONDARY = Color.parseColor("#475569")
        private val TEXT_MUTED = Color.parseColor("#94A3B8")

        private const val EXTRA_IDENTITY = "identity"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_LOCALE = "locale"
        private const val EXTRA_START_ON_OPEN = "start_on_open"

        fun open(
            context: Context,
            identity: VisitorIdentity,
            title: String = "在线客服",
            locale: String? = null,
            startSessionOnOpen: Boolean = false,
        ) {
            context.startActivity(
                Intent(context, HermesLiveChatActivity::class.java)
                    .putExtra(EXTRA_IDENTITY, identity.toJson().toString())
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_LOCALE, locale)
                    .putExtra(EXTRA_START_ON_OPEN, startSessionOnOpen),
            )
        }
    }
}
