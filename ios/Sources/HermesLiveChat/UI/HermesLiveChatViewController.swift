import Foundation
import UIKit

public final class HermesLiveChatLauncher {
    public static func present(
        from viewController: UIViewController,
        identity: VisitorIdentity,
        title: String = "在线客服",
        locale: String? = nil,
        startSessionOnOpen: Bool = false
    ) {
        let page = HermesLiveChatViewController(
            identity: identity,
            title: title,
            locale: locale,
            startSessionOnOpen: startSessionOnOpen
        )
        viewController.navigationController?.pushViewController(page, animated: true)
            ?? viewController.present(UINavigationController(rootViewController: page), animated: true)
    }
}

public final class HermesLiveChatViewController: UIViewController {
    private let identity: VisitorIdentity
    private let locale: String?
    private let startSessionOnOpen: Bool
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let input = UITextField()
    private let errorBanner = UILabel()
    private let composer = UIStackView()
    private let attachButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let loadingStack = UIStackView()
    private let loadingDots = LoadingDotsView()
    private let loadingLabel = UILabel()
    // 自定义 header 的状态点与状态文案（绑定实时连接态）。
    private let headerStatusDot = UIView()
    private let headerStatusLabel = UILabel()
    private var composerBottomConstraint: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var messageKeys = Set<String>()
    private var readMarkedMessageIds = Set<String>()
    private var shownEventErrorMessages = Set<String>()
    private var started = false
    private var sessionBlocked = false {
        didSet { updateComposerState() }
    }
    private var eventsTask: Task<Void, Never>?
    private var welcomePlaceholder: UIView?
    private var welcomePlaceholderText: String?
    private var hasPersistedWelcome = false
    private var pendingBubble: UIView?
    private var pendingText: String?
    private var suppressMessageScroll = false
    private var needsScrollAfterSuppressedUpdate = false
    // Closed-conversation ids whose messages can be pulled in as history on
    // demand. Populated when a session opens; the messages themselves are not
    // loaded until the visitor taps the toggle bar or scrolls to the top.
    private var historyConversationIds: [String] = []
    private var historyLoading = false
    private var historyToggle: UIButton?
    private var isLoadingInitialState = false {
        didSet { updateComposerState() }
    }
    private var isSending = false {
        didSet { updateComposerState() }
    }
    private var isUploadingImage = false {
        didSet { updateComposerState() }
    }
    private static let bubbleMaxWidthRatio: CGFloat = 0.78
    private static let bubbleMaxWidthCap: CGFloat = 520
    private static let imageBubbleWidth: CGFloat = 220
    private static let imageBubbleMaxHeight: CGFloat = 320
    private static let maxImageBytes = 10 * 1024 * 1024

    public init(
        identity: VisitorIdentity,
        title: String = "在线客服",
        locale: String? = nil,
        startSessionOnOpen: Bool = false
    ) {
        self.identity = identity
        self.locale = locale
        self.startSessionOnOpen = startSessionOnOpen
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.screenBackground
        buildUI()
        observeKeyboard()
        observeEvents()
        Task { await loadInitialState() }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            eventsTask?.cancel()
        }
    }

    deinit {
        eventsTask?.cancel()
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func buildUI() {
        configureHeader()
        configureScroll()
        configureErrorBanner()
        configureComposer()
        configureLoading()
        installLayoutConstraints()
    }

    /// 自定义 header：logo 标记 + 标题 + 连接状态圆点，替换系统 nav title，对齐 widget 头部。
    private func configureHeader() {
        // logo 标记：圆角蓝块 + 白色气泡图标。
        let mark = UIView()
        mark.backgroundColor = Palette.primary
        mark.layer.cornerRadius = 7
        mark.translatesAutoresizingMaskIntoConstraints = false
        let markGlyph = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        markGlyph.tintColor = Palette.onPrimary
        markGlyph.contentMode = .scaleAspectFit
        markGlyph.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(markGlyph)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 26),
            mark.heightAnchor.constraint(equalToConstant: 26),
            markGlyph.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            markGlyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            markGlyph.widthAnchor.constraint(equalToConstant: 15),
            markGlyph.heightAnchor.constraint(equalToConstant: 15),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Palette.textPrimary

        headerStatusDot.translatesAutoresizingMaskIntoConstraints = false
        headerStatusDot.layer.cornerRadius = 3.5
        NSLayoutConstraint.activate([
            headerStatusDot.widthAnchor.constraint(equalToConstant: 7),
            headerStatusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        headerStatusLabel.font = .systemFont(ofSize: 12)
        headerStatusLabel.textColor = Palette.textSecondary

        let statusRow = UIStackView(arrangedSubviews: [headerStatusDot, headerStatusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 5

        let textColumn = UIStackView(arrangedSubviews: [titleLabel, statusRow])
        textColumn.axis = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        let header = UIStackView(arrangedSubviews: [mark, textColumn])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 9
        navigationItem.titleView = header

        // 初始为「未连接」，随 connectionStateChanged 事件更新。
        updateConnectionStatus(.idle)
    }

    /// 把实时连接态映射到 header 状态点颜色 + 文案（规则来自纯函数 [ConnectionStatusPresenter]）。
    private func updateConnectionStatus(_ state: LiveChatConnectionState) {
        headerStatusDot.backgroundColor = Palette.color(for: ConnectionStatusPresenter.tone(for: state))
        headerStatusLabel.text = ConnectionStatusPresenter.label(for: state)
    }

    private func configureScroll() {
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)
        view.addSubview(scroll)
    }

    private func configureComposer() {
        input.placeholder = "输入消息"
        input.borderStyle = .roundedRect
        input.returnKeyType = .send
        input.delegate = self
        input.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 附件按钮：圆形、透明底、弱色图标（与 widget 一致）。
        attachButton.setImage(UIImage(systemName: "photo"), for: .normal)
        attachButton.tintColor = Palette.textMuted
        attachButton.accessibilityLabel = "发送图片"
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        attachButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        attachButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // 发送按钮：圆形蓝底 + 白色上箭头图标（替代原「发送」文字按钮）。
        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.tintColor = Palette.onPrimary
        sendButton.backgroundColor = Palette.primary
        sendButton.layer.cornerRadius = 20
        sendButton.layer.masksToBounds = true
        sendButton.accessibilityLabel = "发送"
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        updateComposerState()
        composer.axis = .horizontal
        composer.spacing = 8
        composer.alignment = .center
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.addArrangedSubview(attachButton)
        composer.addArrangedSubview(input)
        composer.addArrangedSubview(sendButton)
        view.addSubview(composer)
    }

    private func configureErrorBanner() {
        errorBanner.isHidden = true
        errorBanner.numberOfLines = 0
        errorBanner.font = .preferredFont(forTextStyle: .footnote)
        errorBanner.adjustsFontForContentSizeCategory = true
        errorBanner.textColor = Palette.errorText
        errorBanner.backgroundColor = Palette.errorBackground
        errorBanner.layer.cornerRadius = 8
        errorBanner.layer.masksToBounds = true
        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorBanner)
    }

    private func configureLoading() {
        loadingLabel.text = "正在加载..."
        loadingLabel.font = .preferredFont(forTextStyle: .subheadline)
        loadingLabel.textColor = Palette.textSecondary
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingStack.axis = .horizontal
        loadingStack.alignment = .center
        loadingStack.spacing = 10
        loadingStack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        loadingStack.isLayoutMarginsRelativeArrangement = true
        loadingStack.backgroundColor = Palette.surface
        loadingStack.layer.cornerRadius = 20
        loadingStack.layer.shadowColor = UIColor.black.cgColor
        loadingStack.layer.shadowOpacity = 0.08
        loadingStack.layer.shadowRadius = 14
        loadingStack.layer.shadowOffset = CGSize(width: 0, height: 8)
        loadingStack.isHidden = true
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingDots.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.addArrangedSubview(loadingDots)
        loadingStack.addArrangedSubview(loadingLabel)
        view.addSubview(loadingStack)
    }

    private func installLayoutConstraints() {
        let bottom = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        composerBottomConstraint = bottom
        NSLayoutConstraint.activate([
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            errorBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            errorBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            loadingStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            loadingDots.widthAnchor.constraint(equalToConstant: 44),
            loadingDots.heightAnchor.constraint(equalToConstant: 18),
            bottom,
        ])
    }

    private func loadInitialState() async {
        await MainActor.run { setLoading("正在加载会话...") }
        if startSessionOnOpen {
            _ = await ensureSession()
        }
        if (!startSessionOnOpen || !started) && !sessionBlocked {
            await loadWelcome()
        }
        await MainActor.run { setLoading(nil) }
    }

    private func observeKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboard(notification)
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboard(notification)
            },
        ]
    }

    private func handleKeyboard(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY - view.safeAreaInsets.bottom)
        composerBottomConstraint?.constant = -8 - overlap
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [options, .beginFromCurrentState]
        ) {
            self.view.layoutIfNeeded()
            self.scrollToBottom(animated: false)
        }
    }

    private func observeEvents() {
        eventsTask = Task {
            for await event in HermesLiveChat.shared.events() {
                await MainActor.run {
                    switch event {
                    case .connectionStateChanged(let state):
                        updateConnectionStatus(state)
                    case .messageReceived(let message, _):
                        addMessage(message)
                    case .conversationUpdated(let conversation):
                        if conversation.status == "closed" { started = false }
                    case .error(let error):
                        if let message = Self.userVisibleErrorMessage(error) {
                            showErrorOnce(message)
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    private func loadWelcome() async {
        do {
            let welcome = try await HermesLiveChat.shared.prefetchWelcome(locale: locale)
            if !welcome.isEmpty {
                await MainActor.run {
                    clearErrorBanner()
                    showWelcomePlaceholder(welcome)
                }
            }
        } catch {
            await MainActor.run { showError("加载欢迎语失败") }
        }
    }

    private func ensureSession() async -> Bool {
        guard !started else { return true }
        do {
            try await HermesLiveChat.shared.startSession(identity)
            started = true
            await MainActor.run {
                sessionBlocked = false
            }
            let activeId = HermesLiveChat.shared.currentConversationId
            // Closed conversations are not loaded eagerly: record their ids so
            // the toggle bar knows there is earlier history to pull in on demand.
            let closedIds = (try? await HermesLiveChat.shared.conversations())
                .map { Self.closedConversationIds($0, activeId: activeId) } ?? []
            if let id = activeId {
                let messages = try await HermesLiveChat.shared.history(conversationId: id)
                await MainActor.run { messages.forEach { addMessage($0, allowPendingClaim: false) } }
            }
            // Render the prefetched welcome whenever there is no active
            // conversation — first visit, or the previous one is closed.
            // Closed-conversation history is collapsed behind the toggle; the
            // new chat starts with its greeting on top.
            if activeId == nil {
                await loadWelcome()
            }
            await MainActor.run {
                clearErrorBanner()
                historyConversationIds = closedIds
                refreshHistoryToggle()
            }
            return true
        } catch {
            await MainActor.run { handleError(error, fallback: "初始化会话失败") }
            return false
        }
    }

    // closedConversationIds lists the most recent closed conversations whose
    // messages can be pulled in as history, newest first and capped to keep the
    // on-demand fetch bounded. The active conversation (if any) is excluded — it
    // is the live thread, not history.
    private static func closedConversationIds(_ conversations: [Conversation], activeId: String?) -> [String] {
        var ids: [String] = []
        for item in conversations {
            if ids.count >= 3 { break }
            if item.uuid.isEmpty || item.uuid == activeId { continue }
            if item.status != "closed" { continue }
            if !ids.contains(item.uuid) { ids.append(item.uuid) }
        }
        return ids
    }

    @objc private func sendTapped() {
        guard !isSending && !isUploadingImage && !sessionBlocked else { return }
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        input.text = ""
        isSending = true
        showPendingBubble(text)
        Task {
            defer {
                Task { @MainActor in
                    self.isSending = false
                }
            }
            guard await ensureSession() else {
                await MainActor.run {
                    performMessageUpdatesWithoutAnimation {
                        removePendingBubble()
                    }
                    input.text = text
                }
                return
            }
            do {
                let messages = try await HermesLiveChat.shared.sendTextMessages(text)
                await MainActor.run {
                    performMessageUpdatesWithoutAnimation {
                        clearErrorBanner()
                        messages.forEach { addMessage($0) }
                        removePendingBubble()
                    }
                }
            } catch {
                await MainActor.run {
                    performMessageUpdatesWithoutAnimation {
                        removePendingBubble()
                    }
                    input.text = text
                    handleError(error, fallback: "发送失败")
                }
            }
        }
    }

    @objc private func attachTapped() {
        guard !isSending && !isUploadingImage && !sessionBlocked else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = ["public.image"]
        picker.delegate = self
        present(picker, animated: true)
    }

    private func sendImage(_ image: UIImage) {
        guard !isUploadingImage && !sessionBlocked else { return }
        guard let data = image.jpegData(compressionQuality: 0.88) else {
            showError("读取图片失败")
            return
        }
        guard data.count > 0, data.count <= Self.maxImageBytes else {
            showError("图片不能超过 10MB")
            return
        }
        isUploadingImage = true
        Task {
            defer {
                Task { @MainActor in
                    self.isUploadingImage = false
                }
            }
            guard await ensureSession() else { return }
            do {
                let messages = try await HermesLiveChat.shared.sendImageMessages(
                    data: data,
                    mimeType: "image/jpeg",
                    filename: "image_\(Int(Date().timeIntervalSince1970)).jpg"
                )
                await MainActor.run {
                    clearErrorBanner()
                    messages.forEach { addMessage($0) }
                }
            } catch {
                await MainActor.run { handleError(error, fallback: "图片发送失败") }
            }
        }
    }

    @MainActor
    private func setLoading(_ text: String?) {
        if let text {
            isLoadingInitialState = true
            loadingLabel.text = text
            loadingStack.isHidden = false
            loadingDots.startAnimating()
        } else {
            isLoadingInitialState = false
            loadingDots.stopAnimating()
            loadingStack.isHidden = true
        }
    }

    private func updateComposerState() {
        let hasText = !(input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let busy = isLoadingInitialState || isSending || isUploadingImage || sessionBlocked
        input.isEnabled = !busy
        attachButton.isEnabled = !busy
        let canSend = !busy && hasText
        sendButton.isEnabled = canSend
        // 圆形图标按钮：用底色透明度表达可用 / 不可用，替代原文字态。
        sendButton.backgroundColor = canSend ? Palette.primary : Palette.primary.withAlphaComponent(0.4)
        // 会话不可用时给出无障碍提示，文案不再占用按钮本身。
        sendButton.accessibilityLabel = sessionBlocked ? "会话不可用" : "发送"
    }

    @objc private func inputChanged() {
        updateComposerState()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @MainActor
    private func handleError(_ error: Error, fallback: String) {
        if let livechatError = error as? HermesLiveChatException,
           livechatError.error == .appInitTokenInvalid || livechatError.error == .appInitTokenExpired {
            guard !sessionBlocked else { return }
            blockSession(livechatError.message ?? "App 身份 token 无效，请刷新身份后重试")
            return
        }
        guard !sessionBlocked else { return }
        showError((error as? HermesLiveChatException)?.message ?? fallback)
    }

    private func showError(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        errorBanner.text = "  \(trimmed.isEmpty ? "操作失败，请稍后重试" : trimmed)  "
        errorBanner.isHidden = false
    }

    private func clearErrorBanner() {
        guard !sessionBlocked else { return }
        errorBanner.text = nil
        errorBanner.isHidden = true
    }

    private func showErrorOnce(_ text: String) {
        guard shownEventErrorMessages.insert(text).inserted else { return }
        showError(text)
    }

    private func blockSession(_ message: String) {
        if !sessionBlocked {
            sessionBlocked = true
            removePendingBubble()
            removeWelcomePlaceholder()
            showError(message)
        }
        started = false
    }

    private static func userVisibleErrorMessage(_ error: HermesLiveChatException) -> String? {
        switch error.error {
        case .network:
            return nil
        case .realtimeProviderUnavailable:
            return "连接暂时异常，请稍后再试。"
        case .realtimeConnectUnauthorized, .tokenInvalid, .tokenExpired:
            return "会话已过期，请重新进入客服。"
        case .notConfigured:
            return "客服暂不可用，请稍后再试。"
        default:
            return nil
        }
    }

    private func showWelcomePlaceholder(_ text: String) {
        // Skip the "already rendered a welcome / messages exist" guards when
        // there is no active conversation — closed history from a prior chat
        // should not suppress the greeting for the new one.
        let hasActive = HermesLiveChat.shared.currentConversationId != nil
        if hasActive {
            guard !hasPersistedWelcome else { return }
            guard messageKeys.isEmpty else { return }
        }
        guard welcomePlaceholder == nil else { return }
        let row = makeTextRow(text: text, mine: false, createdAt: Self.nowSeconds())
        if let pendingBubble, let index = stack.arrangedSubviews.firstIndex(where: { $0 === pendingBubble }) {
            stack.insertArrangedSubview(row, at: index)
            requestMessageScrollToBottom()
        } else {
            stack.addArrangedSubview(row)
            requestMessageScrollToBottom()
        }
        welcomePlaceholder = row
        welcomePlaceholderText = text
    }

    private func removeWelcomePlaceholder() {
        guard let view = welcomePlaceholder else { return }
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        welcomePlaceholder = nil
        welcomePlaceholderText = nil
    }

    // showPendingBubble renders the visitor's outgoing text optimistically while
    // the send is in flight. It is appended after the welcome placeholder, so the
    // greeting stays on top; removePendingBubble clears it before the server's
    // ordered [welcome, visitor] messages are added, which keeps the welcome
    // above the confirmed message instead of being re-appended below it.
    private func showPendingBubble(_ text: String) {
        removePendingBubble()
        pendingText = text
        pendingBubble = addBubble(text, mine: true, createdAt: Self.nowSeconds())
    }

    private func removePendingBubble() {
        guard let view = pendingBubble else { return }
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        pendingBubble = nil
        pendingText = nil
    }

    // refreshHistoryToggle shows or hides the "view earlier messages" bar at the
    // top of the list. It appears only while there is unloaded closed history.
    private func refreshHistoryToggle() {
        let shouldShow = !historyConversationIds.isEmpty
        guard shouldShow else {
            if let toggle = historyToggle {
                stack.removeArrangedSubview(toggle)
                toggle.removeFromSuperview()
                historyToggle = nil
            }
            return
        }
        let toggle = historyToggle ?? makeHistoryToggle()
        if historyToggle == nil {
            historyToggle = toggle
            stack.insertArrangedSubview(toggle, at: 0)
        } else if stack.arrangedSubviews.first !== toggle {
            stack.removeArrangedSubview(toggle)
            stack.insertArrangedSubview(toggle, at: 0)
        }
        toggle.setTitle(historyLoading ? "正在加载更早消息..." : "查看更早消息", for: .normal)
        toggle.isEnabled = !historyLoading
    }

    private func makeHistoryToggle() -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.setTitleColor(Palette.textMuted, for: .normal)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        button.addTarget(self, action: #selector(historyToggleTapped), for: .touchUpInside)
        return button
    }

    @objc private func historyToggleTapped() {
        Task { await loadHistory() }
    }

    // loadHistory pulls in one closed conversation at a time, newest first, and
    // reveals it while keeping the visitor's view anchored. If more history is
    // available the toggle remains so the visitor can keep paging upward.
    private func loadHistory() async {
        guard !historyLoading, let conversationId = historyConversationIds.first else { return }
        historyLoading = true
        await MainActor.run { refreshHistoryToggle() }
        do {
            let loaded = try await HermesLiveChat.shared.conversationMessages(conversationId: conversationId)
            await MainActor.run {
                clearErrorBanner()
                historyConversationIds.removeFirst()
                prependHistory(loaded)
            }
        } catch {
            await MainActor.run { handleError(error, fallback: "加载更早消息失败") }
        }
        historyLoading = false
        await MainActor.run { refreshHistoryToggle() }
    }

    // prependHistory inserts older messages above the current chat, below the
    // toggle bar, and keeps the visitor anchored on what they were reading by
    // offsetting the scroll by the height the inserted rows added.
    private func prependHistory(_ history: [Message]) {
        view.layoutIfNeeded()
        let previousHeight = scroll.contentSize.height
        let previousOffset = scroll.contentOffset.y
        var insertAt = historyToggle != nil ? 1 : 0
        for message in history {
            if let key = messageKey(message), !messageKeys.insert(key).inserted { continue }
            let row = makeMessageRow(message, mine: message.isMine)
            stack.insertArrangedSubview(row, at: insertAt)
            insertAt += 1
            markMessageReadIfNeeded(message)
        }
        // Hide the toggle now that history is loaded, then restore the reading
        // position once layout settles with the new rows measured.
        refreshHistoryToggle()
        view.layoutIfNeeded()
        scroll.contentOffset.y = previousOffset + (scroll.contentSize.height - previousHeight)
    }

    private func addMessage(_ message: Message, allowPendingClaim: Bool = true) {
        if let key = messageKey(message), !messageKeys.insert(key).inserted {
            return
        }
        if message.contentKind == .welcome {
            hasPersistedWelcome = true
            if claimWelcomePlaceholder(for: message) {
                markMessageReadIfNeeded(message)
                requestMessageScrollToBottom()
                return
            }
            if insertWelcomeBeforePendingIfNeeded(message) {
                markMessageReadIfNeeded(message)
                requestMessageScrollToBottom()
                return
            }
        }
        if allowPendingClaim, claimPendingBubble(for: message) {
            requestMessageScrollToBottom()
            return
        }
        addBubble(message, mine: message.isMine)
        markMessageReadIfNeeded(message)
    }

    private func claimWelcomePlaceholder(for message: Message) -> Bool {
        guard message.contentKind == .welcome, let placeholder = welcomePlaceholder else { return false }

        let incoming = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = welcomePlaceholderText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incoming.isEmpty, let existing, incoming != existing {
            let row = makeMessageRow(message, mine: message.isMine)
            replaceArrangedSubview(placeholder, with: row)
        } else if let pendingBubble,
                  let welcomeIndex = stack.arrangedSubviews.firstIndex(where: { $0 === placeholder }),
                  let pendingIndex = stack.arrangedSubviews.firstIndex(where: { $0 === pendingBubble }),
                  welcomeIndex > pendingIndex {
            stack.removeArrangedSubview(placeholder)
            stack.insertArrangedSubview(placeholder, at: pendingIndex)
        }
        welcomePlaceholder = nil
        welcomePlaceholderText = nil
        return true
    }

    private func insertWelcomeBeforePendingIfNeeded(_ message: Message) -> Bool {
        guard message.contentKind == .welcome, let pendingBubble else { return false }
        let row = makeMessageRow(message, mine: message.isMine)
        if let index = stack.arrangedSubviews.firstIndex(where: { $0 === pendingBubble }) {
            stack.insertArrangedSubview(row, at: index)
        } else {
            stack.addArrangedSubview(row)
        }
        return true
    }

    private func claimPendingBubble(for message: Message) -> Bool {
        guard let pendingRow = pendingBubble else { return false }
        guard message.isMine, message.contentKind == .text else { return false }

        let incoming = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = pendingText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected, expected != incoming {
            let row = makeMessageRow(message, mine: true)
            replaceArrangedSubview(pendingRow, with: row)
        }

        pendingBubble = nil
        pendingText = nil
        return true
    }

    private func replaceArrangedSubview(_ oldView: UIView, with newView: UIView) {
        let index = stack.arrangedSubviews.firstIndex { $0 === oldView }
        stack.removeArrangedSubview(oldView)
        oldView.removeFromSuperview()
        if let index {
            stack.insertArrangedSubview(newView, at: index)
        } else {
            stack.addArrangedSubview(newView)
        }
    }

    private func markMessageReadIfNeeded(_ message: Message) {
        guard !message.isMine else { return }
        guard message.readAt == nil else { return }
        let messageId = message.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationId = message.conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageId.isEmpty, !conversationId.isEmpty else { return }
        guard readMarkedMessageIds.insert(messageId).inserted else { return }

        Task { [weak self] in
            do {
                try await HermesLiveChat.shared.markRead(conversationId: conversationId, messageId: messageId)
            } catch {
                await MainActor.run {
                    _ = self?.readMarkedMessageIds.remove(messageId)
                }
            }
        }
    }

    private func messageKey(_ message: Message) -> String? {
        let uuid = message.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !uuid.isEmpty { return uuid }
        let clientMsgId = message.clientMsgId.trimmingCharacters(in: .whitespacesAndNewlines)
        return clientMsgId.isEmpty ? nil : clientMsgId
    }

    @discardableResult
    private func addBubble(_ text: String, mine: Bool, createdAt: Int?) -> UIView {
        let row = makeTextRow(text: text, mine: mine, createdAt: createdAt)
        stack.addArrangedSubview(row)
        requestMessageScrollToBottom()
        return row
    }

    @discardableResult
    private func addBubble(_ message: Message, mine: Bool) -> UIView {
        let row = makeMessageRow(message, mine: mine)
        stack.addArrangedSubview(row)
        requestMessageScrollToBottom()
        return row
    }

    // makeMessageRow builds a message row without appending it or scrolling, so
    // callers can insert it at an arbitrary position (e.g. prepended history).
    private func makeMessageRow(_ message: Message, mine: Bool) -> UIView {
        let bubble = makeMessageBubbleView(message, mine: mine)
        let column = makeBubbleColumn(mine: mine, bubble: bubble, createdAt: message.createdAt)
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        activateBubbleConstraints(row: row, column: column, bubble: bubble, mine: mine)
        return row
    }

    private func makeTextRow(text: String, mine: Bool, createdAt: Int?) -> UIView {
        let bubble = makeBubbleView(text: text, mine: mine)
        let column = makeBubbleColumn(mine: mine, bubble: bubble, createdAt: createdAt)
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        activateBubbleConstraints(row: row, column: column, bubble: bubble, mine: mine)
        return row
    }

    private func makeBubbleView(text: String, mine: Bool) -> UIView {
        // 本人消息纯文本展示；对方消息走 markdown 块栈渲染，与 widget 对齐。
        mine ? makePlainBubbleView(text: text) : makeMarkdownBubbleView(text: text)
    }

    /// 访客（本人）气泡：纯文本 + 主色实底。
    private func makePlainBubbleView(text: String) -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byWordWrapping
        label.textColor = Palette.onPrimary
        label.text = text
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bubble = makeBubbleContainer(mine: true)
        bubble.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
        return bubble
    }

    /// 对方（bot / 客服 / 系统）气泡：swift-markdown 渲染出的块视图纵向栈 + 白底描边。
    private func makeMarkdownBubbleView(text: String) -> UIView {
        let renderer = MarkdownRenderer(
            baseFont: .preferredFont(forTextStyle: .body),
            textColor: Palette.textPrimary,
            imageWidth: Self.imageBubbleWidth
        )
        let blocks = renderer.makeViews(from: text)
        // 解析不出任何块（如纯空白）时兜底成一个纯文本标签，避免气泡空白。
        let arranged = blocks.isEmpty ? [Self.fallbackLabel(text)] : blocks

        let content = UIStackView(arrangedSubviews: arranged)
        content.axis = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false

        let bubble = makeBubbleContainer(mine: false)
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
        return bubble
    }

    /// 气泡容器：圆角 16 + 配色；非 mine（bot）加 1pt 描边。
    private func makeBubbleContainer(mine: Bool) -> UIView {
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = mine ? Palette.primary : Palette.surface
        bubble.layer.cornerRadius = 16
        bubble.layer.masksToBounds = true
        if !mine {
            bubble.layer.borderWidth = 1
            bubble.layer.borderColor = Palette.botBubbleBorder.cgColor
        }
        return bubble
    }

    /// markdown 渲染兜底标签（解析为空时使用）。
    private static func fallbackLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = Palette.textPrimary
        label.text = text
        return label
    }

    private func makeMessageBubbleView(_ message: Message, mine: Bool) -> UIView {
        if MessageContentType.from(message.contentType) == .image,
           let url = message.content["url"] as? String, !url.isEmpty {
            return makeImageBubbleView(url: url, mine: mine)
        }
        return makeBubbleView(text: message.displayText, mine: mine)
    }

    private func makeImageBubbleView(url: String, mine: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = mine ? Palette.primary : Palette.surface
        container.layer.cornerRadius = 16
        container.layer.masksToBounds = true
        if !mine {
            container.layer.borderWidth = 1
            container.layer.borderColor = Palette.botBubbleBorder.cgColor
        }

        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = Palette.surfaceMuted
        container.addSubview(imageView)
        let heightConstraint = imageView.heightAnchor.constraint(equalToConstant: 170)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            imageView.widthAnchor.constraint(equalToConstant: Self.imageBubbleWidth),
            heightConstraint,
        ])
        Task {
            guard
                let remoteURL = URL(string: url),
                let (data, _) = try? await URLSession.shared.data(from: remoteURL),
                let image = UIImage(data: data)
            else { return }
            await MainActor.run {
                imageView.image = image
                heightConstraint.constant = Self.displayHeight(for: image.size)
                self.view.layoutIfNeeded()
            }
        }
        return container
    }

    private static func displayHeight(for imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 170 }
        let aspectHeight = imageBubbleWidth * imageSize.height / imageSize.width
        return min(max(aspectHeight, 96), imageBubbleMaxHeight)
    }

    private func makeBubbleColumn(mine: Bool, bubble: UIView, createdAt: Int?) -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 2
        column.alignment = mine ? .trailing : .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(bubble)
        if let createdAt = createdAt, createdAt > 0 {
            column.addArrangedSubview(makeTimestampLabel(createdAt))
        }
        return column
    }

    private func makeTimestampLabel(_ createdAt: Int) -> UILabel {
        let time = UILabel()
        time.text = Self.formatTime(createdAt)
        time.font = .systemFont(ofSize: 11)
        time.textColor = Palette.textMuted
        return time
    }

    private func activateBubbleConstraints(row: UIView, column: UIStackView, bubble: UIView, mine: Bool) {
        let widthByScreen = column.widthAnchor.constraint(
            lessThanOrEqualTo: row.widthAnchor,
            multiplier: Self.bubbleMaxWidthRatio
        )
        let widthCap = column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.bubbleMaxWidthCap)
        let bubbleWidth = bubble.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor)
        var constraints = [
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            widthByScreen,
            widthCap,
            bubbleWidth,
        ]
        if mine {
            constraints.append(column.trailingAnchor.constraint(equalTo: row.trailingAnchor))
            constraints.append(column.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor))
        } else {
            constraints.append(column.leadingAnchor.constraint(equalTo: row.leadingAnchor))
            constraints.append(column.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static func formatTime(_ seconds: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private static func nowSeconds() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private func requestMessageScrollToBottom() {
        if suppressMessageScroll {
            needsScrollAfterSuppressedUpdate = true
            return
        }
        scrollToBottom()
    }

    private func performMessageUpdatesWithoutAnimation(_ updates: () -> Void) {
        let wasSuppressing = suppressMessageScroll
        suppressMessageScroll = true
        UIView.performWithoutAnimation {
            updates()
            view.layoutIfNeeded()
        }
        suppressMessageScroll = wasSuppressing
        if !wasSuppressing, needsScrollAfterSuppressedUpdate {
            needsScrollAfterSuppressedUpdate = false
            scrollToBottom(animated: false)
        }
    }

    private func scrollToBottom(animated: Bool = true) {
        view.layoutIfNeeded()
        let maxOffsetY = max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        scroll.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
    }
}

extension HermesLiveChatViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return false
    }
}

extension HermesLiveChatViewController: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Pulling to the very top reveals collapsed history, mirroring the toggle
        // bar tap. Guarded inside loadHistory so it fires at most once.
        if scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top {
            Task { await loadHistory() }
        }
    }
}

extension HermesLiveChatViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    public func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            sendImage(image)
        }
    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

private extension Message {
    /// 是否本地访客自己发出（决定左右对齐与是否纯文本展示）。
    var isMine: Bool { MessageSenderType.from(senderType).isMine }
    /// 内容类型枚举，替代裸字符串比较。
    var contentKind: MessageContentType { MessageContentType.from(contentType) }
}

private final class LoadingDotsView: UIView {
    private let dots: [UIView] = (0..<3).map { _ in UIView() }
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.72, 1.18, 0.72]
            scale.keyTimes = [0, 0.38, 1]
            scale.duration = 0.9
            scale.repeatCount = .infinity
            scale.beginTime = now + Double(index) * 0.14
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.35, 1, 0.35]
            opacity.keyTimes = scale.keyTimes
            opacity.duration = scale.duration
            opacity.repeatCount = .infinity
            opacity.beginTime = scale.beginTime
            opacity.timingFunctions = scale.timingFunctions

            dot.layer.add(scale, forKey: "hermes.loading.scale")
            dot.layer.add(opacity, forKey: "hermes.loading.opacity")
        }
    }

    func stopAnimating() {
        isAnimating = false
        dots.forEach {
            $0.layer.removeAnimation(forKey: "hermes.loading.scale")
            $0.layer.removeAnimation(forKey: "hermes.loading.opacity")
        }
    }

    private func buildUI() {
        let stack = UIStackView(arrangedSubviews: dots)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        dots.forEach { dot in
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = Palette.textMuted
            dot.layer.cornerRadius = 3.5
            dot.alpha = 0.35
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
