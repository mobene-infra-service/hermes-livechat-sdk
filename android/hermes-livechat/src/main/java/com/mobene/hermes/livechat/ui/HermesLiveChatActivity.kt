package com.mobene.hermes.livechat.ui

import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextWatcher
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.mobene.hermes.livechat.Conversation
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatError
import com.mobene.hermes.livechat.HermesLiveChatException
import com.mobene.hermes.livechat.HermesLiveChatEvent
import com.mobene.hermes.livechat.LiveChatConnectionState
import com.mobene.hermes.livechat.Message
import com.mobene.hermes.livechat.VisitorIdentity
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

class HermesLiveChatActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var identity: VisitorIdentity
    private lateinit var messages: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText
    private lateinit var status: TextView
    private lateinit var errorBanner: TextView
    private lateinit var composer: LinearLayout
    private lateinit var attachButton: ImageButton
    private lateinit var sendButton: Button
    private lateinit var loadingOverlay: LinearLayout
    private lateinit var loadingDots: LoadingDotsView
    private lateinit var loadingLabel: TextView
    private var started = false
    private var loading = false
    private var sending = false
    private var uploadingImage = false
    private var sessionBlocked = false
    private var eventsJob: Job? = null
    private val messageKeys = mutableSetOf<String>()
    private val readMarkedMessageIds = mutableSetOf<String>()
    private var welcomePlaceholder: View? = null
    private var welcomePlaceholderText: String? = null
    private var hasPersistedWelcome = false
    private var pendingBubble: View? = null
    private var pendingText: String? = null
    private var suppressMessageScroll = false
    private var needsScrollAfterSuppressedUpdate = false
    // Closed-conversation ids whose messages can be pulled in as history on
    // demand. Populated when a session opens; the messages themselves are not
    // loaded until the visitor taps the toggle bar or scrolls to the top.
    private var historyConversationIds: List<String> = emptyList()
    private var historyLoading = false
    private var historyToggle: TextView? = null
    private var historyPullStartY: Float? = null
    private var historyPullTriggered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        identity = VisitorIdentity.fromJson(intent.getStringExtra(EXTRA_IDENTITY).orEmpty())
        title = intent.getStringExtra(EXTRA_TITLE) ?: "在线客服"
        configureWindow()
        buildUi()
        subscribeEvents()
        status.text = HermesLiveChat.connectionState.label()
        if (intent.getBooleanExtra(EXTRA_START_ON_OPEN, false)) {
            bootstrapSessionAndWelcome()
        } else {
            loadWelcome()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PICK_IMAGE && resultCode == RESULT_OK) {
            data?.data?.let(::sendImage)
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
        root.addView(buildErrorBanner(), LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        root.addView(buildScrollContainer(), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(buildComposer(), LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        setContentView(root)
        applyInsets(root)
        status.tag = "status"
    }

    private fun buildScrollContainer(): FrameLayout {
        val container = FrameLayout(this)
        scroll = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
            setPadding(0, dp(6), 0, dp(8))
            // Pulling to the very top reveals collapsed history, mirroring the
            // toggle bar tap. Guarded inside loadHistory so it fires at most once.
            setOnScrollChangeListener { _, _, scrollY, _, _ ->
                if (scrollY <= 0) loadHistory()
            }
            setOnTouchListener { _, event ->
                handleHistoryPull(event)
                false
            }
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
        container.addView(
            scroll,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        loadingOverlay = buildLoadingOverlay()
        container.addView(
            loadingOverlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
        return container
    }

    private fun buildComposer(): LinearLayout {
        composer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            setPadding(dp(16), dp(10), dp(16), dp(10))
            setBackgroundColor(Color.WHITE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(8).toFloat()
            }
        }
        input = buildInputField()
        attachButton = buildAttachButton()
        composer.addView(attachButton, LinearLayout.LayoutParams(dp(42), dp(42)).apply {
            marginEnd = dp(8)
        })
        composer.addView(
            input,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(10)
            },
        )
        sendButton = buildSendButton()
        composer.addView(sendButton, LinearLayout.LayoutParams(dp(72), dp(42)))
        updateSendButtonState()
        return composer
    }

    private fun buildLoadingOverlay(): LinearLayout {
        loadingLabel = TextView(this).apply {
            text = "正在加载..."
            textSize = 13f
            setTextColor(TEXT_SECONDARY)
        }
        return LinearLayout(this).apply {
            visibility = View.GONE
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = rounded(Color.WHITE, BORDER, dp(1), dp(18).toFloat())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(6).toFloat()
            }
            loadingDots = LoadingDotsView(this@HermesLiveChatActivity)
            addView(loadingDots, LinearLayout.LayoutParams(dp(46), dp(22)).apply {
                marginEnd = dp(8)
            })
            addView(loadingLabel)
        }
    }

    private fun buildInputField(): EditText = EditText(this).apply {
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
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = updateSendButtonState()
            override fun afterTextChanged(s: Editable?) = Unit
        })
    }

    private fun buildAttachButton(): ImageButton = ImageButton(this).apply {
        contentDescription = "发送图片"
        setImageResource(android.R.drawable.ic_menu_gallery)
        setColorFilter(TEXT_SECONDARY)
        background = rounded(
            color = Color.WHITE,
            strokeColor = BORDER,
            strokeWidth = dp(1),
            radius = dp(21).toFloat(),
        )
        setPadding(dp(9), dp(9), dp(9), dp(9))
        scaleType = ImageView.ScaleType.CENTER
        setOnClickListener {
            if (!loading && !sending && !uploadingImage) {
                startActivityForResult(
                    Intent(Intent.ACTION_GET_CONTENT).apply {
                        type = "image/*"
                        addCategory(Intent.CATEGORY_OPENABLE)
                    },
                    REQ_PICK_IMAGE,
                )
            }
        }
    }

    private fun buildSendButton(): Button = Button(this).apply {
        text = "发送"
        textSize = 14f
        setTextColor(Color.WHITE)
        isEnabled = false
        alpha = 0.5f
        minWidth = dp(64)
        minHeight = dp(42)
        minimumHeight = 0
        minimumWidth = 0
        background = rounded(PRIMARY, radius = dp(20).toFloat())
        setOnClickListener { sendText() }
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

    private fun buildErrorBanner(): TextView =
        TextView(this).apply {
            visibility = View.GONE
            textSize = 13f
            setTextColor(ERROR_TEXT)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            setBackgroundColor(ERROR_BACKGROUND)
            maxLines = 3
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
                        if (event.conversation.status == "closed") started = false
                    }
                    is HermesLiveChatEvent.MessageRead -> Unit
                    is HermesLiveChatEvent.Error -> handleSessionError(event.error)
                }
            }
        }
    }

    private fun loadWelcome() {
        scope.launch {
            setLoading("正在加载欢迎语...")
            try {
                loadWelcomeOnce()
            } finally {
                setLoading(null)
            }
        }
    }

    private suspend fun loadWelcomeOnce() {
        runCatching {
            HermesLiveChat.prefetchWelcome(intent.getStringExtra(EXTRA_LOCALE))
        }.onSuccess {
            clearErrorBanner()
            if (it.isNotBlank()) showWelcomePlaceholder(it)
        }.onFailure {
            showErrorBanner(it.message ?: "加载欢迎语失败")
        }
    }

    private fun bootstrapSessionAndWelcome() {
        if (started) return
        scope.launch {
            setLoading("正在加载会话...")
            try {
                runCatching {
                    startSessionAndLoadHistory()
                }.onFailure {
                    handleSessionError(it)
                }
                if (!started && !sessionBlocked) loadWelcomeOnce()
            } finally {
                setLoading(null)
            }
        }
    }

    private fun ensureSession() {
        if (started) return
        scope.launch {
            runCatching {
                startSessionAndLoadHistory()
            }.onFailure {
                handleSessionError(it)
            }
        }
    }

    private fun sendText() {
        val text = input.text.toString().trim()
        if (text.isEmpty() || sending || uploadingImage || sessionBlocked) return
        input.setText("")
        setSending(true)
        showPendingBubble(text)
        scope.launch {
            runCatching {
                if (!started) {
                    startSessionAndLoadHistory()
                }
                HermesLiveChat.sendTextMessages(text)
            }.onSuccess {
                performMessageUpdatesWithoutAnimation {
                    clearErrorBanner()
                    it.forEach(::addMessage)
                    removePendingBubble()
                }
            }.onFailure {
                performMessageUpdatesWithoutAnimation {
                    removePendingBubble()
                    input.setText(text)
                    handleSessionError(it, fallback = "发送失败")
                }
            }.also {
                setSending(false)
            }
        }
    }

    private fun sendImage(uri: Uri) {
        if (sending || uploadingImage || sessionBlocked) return
        setUploadingImage(true)
        scope.launch {
            runCatching {
                val attachment = readImageAttachment(uri)
                if (!started) {
                    startSessionAndLoadHistory()
                }
                HermesLiveChat.sendImageMessages(
                    bytes = attachment.bytes,
                    mimeType = attachment.mimeType,
                    filename = attachment.filename,
                )
            }.onSuccess {
                clearErrorBanner()
                it.forEach(::addMessage)
            }.onFailure {
                handleSessionError(it, fallback = "图片发送失败")
            }.also {
                setUploadingImage(false)
            }
        }
    }

    private fun setLoading(text: String?) {
        loading = !text.isNullOrBlank()
        if (text.isNullOrBlank()) {
            loadingOverlay.visibility = View.GONE
            loadingDots.stopAnimating()
            input.isEnabled = !sending && !uploadingImage && !sessionBlocked
            updateSendButtonState()
            return
        }
        loadingLabel.text = text
        loadingOverlay.visibility = View.VISIBLE
        loadingDots.startAnimating()
        input.isEnabled = false
        updateSendButtonState()
    }

    private fun setSending(value: Boolean) {
        sending = value
        input.isEnabled = !value && !loading && !uploadingImage && !sessionBlocked
        updateSendButtonState()
    }

    private fun setUploadingImage(value: Boolean) {
        uploadingImage = value
        input.isEnabled = !value && !loading && !sending && !sessionBlocked
        updateSendButtonState()
    }

    private fun updateSendButtonState() {
        if (!::sendButton.isInitialized) return
        val hasText = input.text.toString().trim().isNotEmpty()
        val busy = loading || sending || uploadingImage || sessionBlocked
        if (::attachButton.isInitialized) {
            attachButton.isEnabled = !busy
            attachButton.alpha = if (busy) 0.5f else 1f
        }
        sendButton.isEnabled = !busy && hasText
        sendButton.text = if (sessionBlocked) {
            "不可用"
        } else if (loading) {
            "加载中"
        } else if (uploadingImage) {
            "上传中"
        } else if (sending) {
            "发送中"
        } else {
            "发送"
        }
        sendButton.alpha = if (busy) {
            0.68f
        } else if (hasText) {
            1f
        } else {
            0.5f
        }
    }

    private fun handleSessionError(error: Throwable, fallback: String = "初始化会话失败") {
        val livechatError = error as? HermesLiveChatException
        if (livechatError?.error == HermesLiveChatError.APP_INIT_TOKEN_INVALID ||
            livechatError?.error == HermesLiveChatError.APP_INIT_TOKEN_EXPIRED
        ) {
            blockSession(livechatError.message ?: "App 身份 token 无效，请刷新身份后重试")
            return
        }
        if (sessionBlocked) return
        showErrorBanner(error.message ?: fallback)
    }

    private fun blockSession(message: String) {
        if (!sessionBlocked) {
            sessionBlocked = true
            performMessageUpdatesWithoutAnimation {
                removePendingBubble()
                removeWelcomePlaceholder()
            }
            showErrorBanner(message)
        }
        started = false
        input.isEnabled = false
        if (::attachButton.isInitialized) {
            attachButton.isEnabled = false
        }
        updateSendButtonState()
    }

    private suspend fun startSessionAndLoadHistory() {
        HermesLiveChat.startSession(identity)
        started = true
        clearErrorBanner()
        val activeId = HermesLiveChat.currentConversationId
        // Closed conversations are not loaded eagerly: record their ids so the
        // toggle bar knows there is earlier history to pull in on demand.
        historyConversationIds = runCatching {
            closedConversationIds(HermesLiveChat.conversations(), activeId)
        }.getOrDefault(emptyList())
        activeId?.let { conversationId ->
            HermesLiveChat.history(conversationId).forEach { addMessage(it, allowPendingClaim = false) }
        }
        // Render the prefetched welcome whenever there is no active
        // conversation — first visit, or the previous one is closed.
        // Closed-conversation history is collapsed behind the toggle; the new
        // chat starts with its greeting on top.
        if (activeId == null) {
            loadWelcomeOnce()
        }
        refreshHistoryToggle()
    }

    // closedConversationIds lists the most recent closed conversations whose
    // messages can be pulled in as history, newest first and capped to keep the
    // on-demand fetch bounded. The active conversation (if any) is excluded — it
    // is the live thread, not history.
    private fun closedConversationIds(conversations: List<Conversation>, activeId: String?): List<String> {
        val ids = mutableListOf<String>()
        for (item in conversations) {
            if (ids.size >= 3) break
            if (item.uuid.isEmpty() || item.uuid == activeId) continue
            if (item.status != "closed") continue
            if (item.uuid !in ids) ids.add(item.uuid)
        }
        return ids
    }

    // refreshHistoryToggle shows or hides the "view earlier messages" bar at the
    // top of the list. It appears only while there is unloaded closed history.
    private fun refreshHistoryToggle() {
        val shouldShow = historyConversationIds.isNotEmpty()
        if (!shouldShow) {
            historyToggle?.let(messages::removeView)
            historyToggle = null
            return
        }
        val toggle = historyToggle ?: buildHistoryToggle().also {
            historyToggle = it
            messages.addView(it, 0)
        }
        if (messages.indexOfChild(toggle) != 0) {
            messages.removeView(toggle)
            messages.addView(toggle, 0)
        }
        toggle.text = if (historyLoading) "正在加载更早消息..." else "查看更早消息"
        toggle.isEnabled = !historyLoading
    }

    private fun buildHistoryToggle(): TextView = TextView(this).apply {
        textSize = 13f
        setTextColor(TEXT_SECONDARY)
        gravity = Gravity.CENTER
        setPadding(dp(16), dp(10), dp(16), dp(10))
        setOnClickListener { loadHistory() }
    }

    // loadHistory pulls in one closed conversation at a time, newest first, and
    // reveals it while keeping the visitor's view anchored. If more history is
    // available the toggle remains so the visitor can keep paging upward.
    private fun loadHistory() {
        if (historyLoading || historyConversationIds.isEmpty()) return
        historyLoading = true
        refreshHistoryToggle()
        scope.launch {
            runCatching {
                val conversationId = historyConversationIds.first()
                HermesLiveChat.conversationMessages(conversationId)
            }.onSuccess { loaded ->
                clearErrorBanner()
                historyConversationIds = historyConversationIds.drop(1)
                prependHistory(loaded)
            }.onFailure {
                handleSessionError(it, fallback = "加载更早消息失败")
            }.also {
                historyLoading = false
                refreshHistoryToggle()
            }
        }
    }

    private fun handleHistoryPull(event: MotionEvent) {
        if (historyLoading || historyConversationIds.isEmpty()) {
            resetHistoryPull()
            return
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                historyPullStartY = if (scroll.scrollY <= 0) event.rawY else null
                historyPullTriggered = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (scroll.scrollY > 0) {
                    resetHistoryPull()
                    return
                }
                val startY = historyPullStartY ?: event.rawY.also {
                    historyPullStartY = it
                }
                if (!historyPullTriggered && event.rawY - startY >= dp(historyPullThresholdDp)) {
                    historyPullTriggered = true
                    loadHistory()
                }
            }
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> resetHistoryPull()
        }
    }

    private fun resetHistoryPull() {
        historyPullStartY = null
        historyPullTriggered = false
    }

    // prependHistory inserts older messages above the current chat, below the
    // toggle bar, and keeps the visitor anchored on what they were reading by
    // offsetting the scroll by the height the inserted rows added.
    private fun prependHistory(history: List<Message>) {
        val previousHeight = messages.height
        val previousScroll = scroll.scrollY
        var insertAt = if (historyToggle != null) 1 else 0
        for (message in history) {
            if (hasMessageIdentity(message)) continue
            rememberMessageKeys(message)
            val row = buildMessageRow(message, mine = message.senderType == "visitor")
            messages.addView(row, insertAt)
            insertAt += 1
            markMessageReadIfNeeded(message)
        }
        // Hide the toggle now that history is loaded, then restore the reading
        // position once layout settles with the new rows measured.
        refreshHistoryToggle()
        scroll.post {
            scroll.scrollTo(0, previousScroll + (messages.height - previousHeight))
        }
    }

    private fun showErrorBanner(text: String) {
        if (!::errorBanner.isInitialized) return
        val message = text.trim().ifEmpty { "操作失败，请稍后重试" }
        errorBanner.text = message
        errorBanner.visibility = View.VISIBLE
    }

    private fun clearErrorBanner() {
        if (!::errorBanner.isInitialized || sessionBlocked) return
        errorBanner.text = ""
        errorBanner.visibility = View.GONE
    }

    private fun showWelcomePlaceholder(text: String) {
        // Skip the "already rendered a welcome / messages exist" guards when
        // there is no active conversation — closed history from a prior chat
        // should not suppress the greeting for the new one.
        val hasActive = HermesLiveChat.currentConversationId != null
        if (hasActive) {
            if (hasPersistedWelcome) return
            if (messageKeys.isNotEmpty()) return
        }
        if (welcomePlaceholder != null) return
        val row = buildTextRow(text, mine = false, createdAt = nowSeconds())
        val pendingIndex = pendingBubble?.let(messages::indexOfChild)?.takeIf { it >= 0 }
        if (pendingIndex != null) {
            messages.addView(row, pendingIndex)
        } else {
            messages.addView(row)
        }
        welcomePlaceholder = row
        welcomePlaceholderText = text
        requestScrollToBottom()
    }

    private fun removeWelcomePlaceholder() {
        welcomePlaceholder?.let(messages::removeView)
        welcomePlaceholder = null
        welcomePlaceholderText = null
    }

    // showPendingBubble renders the visitor's outgoing text optimistically while
    // the send is in flight. Server-confirmed text messages claim this row so
    // the UI does not remove and re-add the bubble when the response arrives.
    private fun showPendingBubble(text: String) {
        removePendingBubble()
        pendingText = text
        pendingBubble = addBubble(text, mine = true, createdAt = nowSeconds())
    }

    private fun removePendingBubble() {
        pendingBubble?.let(messages::removeView)
        pendingBubble = null
        pendingText = null
    }

    private fun addMessage(message: Message, allowPendingClaim: Boolean = true) {
        if (hasMessageIdentity(message)) {
            return
        }
        rememberMessageKeys(message)
        if (message.contentType == "welcome") {
            hasPersistedWelcome = true
            if (claimWelcomePlaceholder(message)) {
                markMessageReadIfNeeded(message)
                requestScrollToBottom()
                return
            }
            if (insertWelcomeBeforePendingIfNeeded(message)) {
                markMessageReadIfNeeded(message)
                requestScrollToBottom()
                return
            }
        }
        if (allowPendingClaim && claimPendingBubble(message)) {
            requestScrollToBottom()
            return
        }

        addBubble(message, mine = message.senderType == "visitor")
        markMessageReadIfNeeded(message)
    }

    private fun claimWelcomePlaceholder(message: Message): Boolean {
        val placeholder = welcomePlaceholder ?: return false
        if (message.contentType != "welcome") return false

        val incoming = messageDisplayText(message).trim()
        val existing = welcomePlaceholderText?.trim()
        if (incoming.isNotEmpty() && existing != null && incoming != existing) {
            replaceMessageRow(placeholder, buildMessageRow(message, mine = message.senderType == "visitor"))
        } else {
            val welcomeIndex = messages.indexOfChild(placeholder)
            val pendingIndex = pendingBubble?.let(messages::indexOfChild) ?: -1
            if (welcomeIndex >= 0 && pendingIndex >= 0 && welcomeIndex > pendingIndex) {
                messages.removeView(placeholder)
                messages.addView(placeholder, pendingIndex)
            }
        }
        welcomePlaceholder = null
        welcomePlaceholderText = null
        return true
    }

    private fun insertWelcomeBeforePendingIfNeeded(message: Message): Boolean {
        if (message.contentType != "welcome") return false
        val pending = pendingBubble ?: return false
        val row = buildMessageRow(message, mine = message.senderType == "visitor")
        val index = messages.indexOfChild(pending)
        if (index >= 0) {
            messages.addView(row, index)
        } else {
            messages.addView(row)
        }
        return true
    }

    private fun claimPendingBubble(message: Message): Boolean {
        val pending = pendingBubble ?: return false
        if (!matchesPending(message)) return false

        val incoming = messageDisplayText(message).trim()
        val expected = pendingText?.trim()
        if (expected != null && incoming != expected) {
            replaceMessageRow(pending, buildMessageRow(message, mine = true))
        }
        pendingBubble = null
        pendingText = null
        return true
    }

    private fun replaceMessageRow(oldView: View, newView: View) {
        val index = messages.indexOfChild(oldView)
        messages.removeView(oldView)
        if (index >= 0) {
            messages.addView(newView, index)
        } else {
            messages.addView(newView)
        }
    }

    private fun markMessageReadIfNeeded(message: Message) {
        val messageId = message.uuid.trim()
        val conversationId = message.conversationId.trim()
        if (message.senderType == "visitor") return
        if (message.readAt != null) return
        if (messageId.isBlank() || conversationId.isBlank()) return
        if (!readMarkedMessageIds.add(messageId)) return

        scope.launch {
            runCatching {
                HermesLiveChat.markRead(conversationId, messageId)
            }.onFailure {
                readMarkedMessageIds.remove(messageId)
            }
        }
    }

    private fun messageDisplayText(message: Message): String {
        val text = message.content.optString("text").trim()
        if (text.isNotEmpty()) return text
        return when (message.contentType) {
            "image" -> ""
            else -> "[${message.contentType}]"
        }
    }

    private fun hasMessageIdentity(message: Message): Boolean =
        message.uuid.takeIf { it.isNotBlank() }?.let(messageKeys::contains) == true ||
            message.clientMsgId.takeIf { it.isNotBlank() }?.let(messageKeys::contains) == true

    private fun rememberMessageKeys(message: Message) {
        message.uuid.takeIf { it.isNotBlank() }?.let(messageKeys::add)
        message.clientMsgId.takeIf { it.isNotBlank() }?.let(messageKeys::add)
    }

    private fun matchesPending(message: Message): Boolean {
        val text = pendingText ?: return false
        return message.senderType == "visitor" &&
            message.contentType == "text" &&
            message.content.optString("text").trim() == text
    }

    private fun addBubble(text: String, mine: Boolean, createdAt: Long? = null): View {
        val row = buildTextRow(text, mine, createdAt)
        messages.addView(row)
        requestScrollToBottom()
        return row
    }

    private fun buildTextRow(text: String, mine: Boolean, createdAt: Long? = null): View {
        val row = bubbleRow(mine)
        val column = bubbleColumn(mine).apply {
            addView(bubbleLabel(text, mine))
            if (createdAt != null && createdAt > 0) addView(bubbleTimestamp(createdAt))
        }
        row.addView(column)
        return row
    }

    private fun addBubble(message: Message, mine: Boolean): View {
        val row = buildMessageRow(message, mine)
        messages.addView(row)
        requestScrollToBottom()
        return row
    }

    private fun requestScrollToBottom() {
        if (suppressMessageScroll) {
            needsScrollAfterSuppressedUpdate = true
            return
        }
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    private fun performMessageUpdatesWithoutAnimation(updates: () -> Unit) {
        val wasSuppressing = suppressMessageScroll
        suppressMessageScroll = true
        messages.suppressLayout(true)
        try {
            updates()
        } finally {
            messages.suppressLayout(false)
            suppressMessageScroll = wasSuppressing
        }
        if (!wasSuppressing && needsScrollAfterSuppressedUpdate) {
            needsScrollAfterSuppressedUpdate = false
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    private fun buildMessageRow(message: Message, mine: Boolean): View {
        val row = bubbleRow(mine)
        val column = bubbleColumn(mine).apply {
            val imageUrl = if (message.contentType == "image") message.content.optString("url").trim() else ""
            if (imageUrl.isNotEmpty()) {
                addView(imageBubble(imageUrl, mine))
            }
            val text = messageDisplayText(message)
            if (text.isNotEmpty() || imageUrl.isEmpty()) {
                addView(bubbleLabel(text.ifEmpty { "[${message.contentType}]" }, mine))
            }
            if (message.createdAt > 0) addView(bubbleTimestamp(message.createdAt))
        }
        row.addView(column)
        return row
    }

    private fun imageBubble(url: String, mine: Boolean): ImageView =
        ImageView(this).apply {
            contentDescription = "图片消息"
            background = rounded(
                color = if (mine) PRIMARY else Color.WHITE,
                strokeColor = if (mine) PRIMARY else BORDER,
                strokeWidth = if (mine) 0 else dp(1),
                radius = dp(16).toFloat(),
            )
            setPadding(dp(4), dp(4), dp(4), dp(4))
            scaleType = ImageView.ScaleType.FIT_CENTER
            adjustViewBounds = true
            minimumHeight = dp(96)
            maxHeight = dp(320)
            layoutParams = LinearLayout.LayoutParams(
                (resources.displayMetrics.widthPixels * 0.58f).toInt(),
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            ImageLoader.load(this, url)
        }

    private fun bubbleRow(mine: Boolean) = LinearLayout(this).apply {
        gravity = if (mine) Gravity.END else Gravity.START
        setPadding(dp(16), dp(4), dp(16), dp(4))
    }

    private fun bubbleColumn(mine: Boolean) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = if (mine) Gravity.END else Gravity.START
    }

    private fun bubbleLabel(text: String, mine: Boolean) = TextView(this).apply {
        this.text = if (mine) text else inlineMarkdown(text)
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

    private fun inlineMarkdown(text: String): CharSequence {
        val result = SpannableStringBuilder()
        var index = 0
        while (index < text.length) {
            val boldMarker = when {
                text.startsWith("**", index) -> "**"
                text.startsWith("__", index) -> "__"
                else -> null
            }
            if (boldMarker != null) {
                val close = text.indexOf(boldMarker, startIndex = index + boldMarker.length)
                if (close > index + boldMarker.length) {
                    result.appendMarkdownSpan(
                        text.substring(index + boldMarker.length, close),
                        StyleSpan(Typeface.BOLD),
                    )
                    index = close + boldMarker.length
                    continue
                }
            }

            if (text[index] == '`') {
                val close = text.indexOf('`', startIndex = index + 1)
                if (close > index + 1) {
                    result.appendMarkdownSpan(
                        text.substring(index + 1, close),
                        TypefaceSpan("monospace"),
                    )
                    index = close + 1
                    continue
                }
            }

            val italicMarker = when (text[index]) {
                '*' -> "*"
                '_' -> "_"
                else -> null
            }
            if (italicMarker != null) {
                val close = text.indexOf(italicMarker, startIndex = index + 1)
                if (close > index + 1) {
                    result.appendMarkdownSpan(
                        text.substring(index + 1, close),
                        StyleSpan(Typeface.ITALIC),
                    )
                    index = close + 1
                    continue
                }
            }

            val next = text.indexOfFirst(index + 1) { it == '*' || it == '_' || it == '`' }
                .takeIf { it >= 0 }
                ?: text.length
            result.append(text.substring(index, next))
            index = next
        }
        return result
    }

    private fun SpannableStringBuilder.appendMarkdownSpan(text: String, span: Any) {
        val start = length
        append(text)
        setSpan(span, start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private inline fun String.indexOfFirst(startIndex: Int, predicate: (Char) -> Boolean): Int {
        for (i in startIndex until length) {
            if (predicate(this[i])) return i
        }
        return -1
    }

    private fun bubbleTimestamp(createdAt: Long) = TextView(this).apply {
        text = formatTime(createdAt)
        textSize = 11f
        setTextColor(TEXT_MUTED)
        setPadding(dp(4), dp(4), dp(4), 0)
    }

    private fun nowSeconds(): Long =
        System.currentTimeMillis() / 1000

    private fun formatTime(seconds: Long): String =
        timeFormatter.format(Date(seconds * 1000))

    private suspend fun readImageAttachment(uri: Uri): ImageAttachment = withContext(Dispatchers.IO) {
        val mimeType = contentResolver.getType(uri)?.takeIf { it.startsWith("image/") } ?: "image/jpeg"
        if (mimeType !in allowedImageMimeTypes) {
            throw IllegalArgumentException("不支持该图片类型")
        }
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maxImageBytes) {
                    throw IllegalArgumentException("图片不能超过 10MB")
                }
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
            ?: throw IllegalArgumentException("读取图片失败")
        if (bytes.isEmpty()) {
            throw IllegalArgumentException("读取图片失败")
        }
        ImageAttachment(
            bytes = bytes,
            mimeType = mimeType,
            filename = "image_${System.currentTimeMillis()}.${imageExtension(mimeType)}",
        )
    }

    private fun imageExtension(mimeType: String): String = when (mimeType.lowercase(Locale.US)) {
        "image/png" -> "png"
        "image/gif" -> "gif"
        else -> "jpg"
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
        private val ERROR_BACKGROUND = Color.parseColor("#FEF2F2")
        private val ERROR_TEXT = Color.parseColor("#B91C1C")
        private val TEXT_PRIMARY = Color.parseColor("#111827")
        private val TEXT_SECONDARY = Color.parseColor("#475569")
        private val TEXT_MUTED = Color.parseColor("#94A3B8")

        private const val maxImageBytes = 10 * 1024 * 1024
        private const val historyPullThresholdDp = 48
        private val allowedImageMimeTypes = setOf("image/jpeg", "image/png", "image/gif")
        private val timeFormatter = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault())

        private const val EXTRA_IDENTITY = "identity"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_LOCALE = "locale"
        private const val EXTRA_START_ON_OPEN = "start_on_open"
        private const val REQ_PICK_IMAGE = 9011

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

private data class ImageAttachment(
    val bytes: ByteArray,
    val mimeType: String,
    val filename: String,
)

private object ImageLoader {
    fun load(target: ImageView, url: String) {
        Thread {
            runCatching {
                URL(url).openStream().use(BitmapFactory::decodeStream)
            }.onSuccess { bitmap ->
                target.post {
                    if (bitmap == null) {
                        target.setImageResource(android.R.drawable.ic_menu_report_image)
                        return@post
                    }
                    target.setImageBitmap(bitmap)
                    updateImageBounds(target, bitmap.width, bitmap.height)
                }
            }.onFailure {
                target.post {
                    target.setImageResource(android.R.drawable.ic_menu_report_image)
                }
            }
        }.start()
    }

    private fun updateImageBounds(target: ImageView, imageWidth: Int, imageHeight: Int) {
        val params = target.layoutParams ?: return
        val width = if (params.width > 0) {
            params.width
        } else {
            (target.resources.displayMetrics.widthPixels * 0.58f).toInt()
        }
        val contentWidth = max(1, width - target.paddingLeft - target.paddingRight)
        val density = target.resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density + 0.5f).toInt()
        val contentHeight = if (imageWidth > 0 && imageHeight > 0) {
            (contentWidth * imageHeight / imageWidth.toFloat()).toInt()
        } else {
            dp(180)
        }
        params.height = (contentHeight + target.paddingTop + target.paddingBottom)
            .coerceIn(dp(96), dp(320))
        target.layoutParams = params
    }
}

private class LoadingDotsView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#64748B")
    }
    private val animator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 1050L
        repeatCount = ValueAnimator.INFINITE
        addUpdateListener {
            phase = it.animatedValue as Float
            invalidate()
        }
    }
    private var phase = 0f

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density
        val baseRadius = 3.5f * density
        val spacing = 13f * density
        val centerY = height / 2f
        val startX = width / 2f - spacing

        repeat(3) { index ->
            val wave = ((sin((phase + index * 0.16f) * 2f * PI) + 1f) / 2f).toFloat()
            val scale = 0.72f + wave * 0.36f
            paint.alpha = (90 + wave * 165).toInt()
            canvas.drawCircle(startX + spacing * index, centerY, baseRadius * scale, paint)
        }
    }

    override fun onDetachedFromWindow() {
        stopAnimating()
        super.onDetachedFromWindow()
    }

    fun startAnimating() {
        if (!animator.isStarted) animator.start()
    }

    fun stopAnimating() {
        if (animator.isStarted) animator.cancel()
    }
}
