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
    private let composer = UIStackView()
    private let attachButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let loadingStack = UIStackView()
    private let loadingDots = LoadingDotsView()
    private let loadingLabel = UILabel()
    private var composerBottomConstraint: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var messageKeys = Set<String>()
    private var readMarkedMessageIds = Set<String>()
    private var shownEventErrorMessages = Set<String>()
    private var started = false
    private var eventsTask: Task<Void, Never>?
    private var welcomePlaceholder: UIView?
    private var hasPersistedWelcome = false
    private var pendingBubble: UIView?
    // Closed-conversation ids whose messages can be pulled in as history on
    // demand. Populated when a session opens; the messages themselves are not
    // loaded until the visitor taps the toggle bar or scrolls to the top.
    private var historyConversationIds: [String] = []
    private var historyExpanded = false
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
        view.backgroundColor = .systemBackground
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
        configureScroll()
        configureComposer()
        configureLoading()
        installLayoutConstraints()
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
        attachButton.setImage(UIImage(systemName: "photo"), for: .normal)
        attachButton.accessibilityLabel = "发送图片"
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        attachButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        attachButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        sendButton.setTitle("发送", for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        updateComposerState()
        composer.axis = .horizontal
        composer.spacing = 8
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.addArrangedSubview(attachButton)
        composer.addArrangedSubview(input)
        composer.addArrangedSubview(sendButton)
        view.addSubview(composer)
    }

    private func configureLoading() {
        loadingLabel.text = "正在加载..."
        loadingLabel.font = .preferredFont(forTextStyle: .subheadline)
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingStack.axis = .horizontal
        loadingStack.alignment = .center
        loadingStack.spacing = 10
        loadingStack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        loadingStack.isLayoutMarginsRelativeArrangement = true
        loadingStack.backgroundColor = .secondarySystemBackground
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
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
            await ensureSession()
        }
        if !startSessionOnOpen || !started {
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
                    case .messageReceived(let message, _):
                        addMessage(message)
                    case .conversationUpdated(let conversation):
                        if conversation.status == "closed" { started = false }
                    case .error(let error):
                        if let message = Self.userVisibleErrorMessage(error) {
                            addSystemOnce(message)
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
            if !welcome.isEmpty { await MainActor.run { showWelcomePlaceholder(welcome) } }
        } catch {
            await MainActor.run { addSystem("加载欢迎语失败") }
        }
    }

    private func ensureSession() async {
        guard !started else { return }
        do {
            try await HermesLiveChat.shared.startSession(identity)
            started = true
            let activeId = HermesLiveChat.shared.currentConversationId
            // Closed conversations are not loaded eagerly: record their ids so
            // the toggle bar knows there is earlier history to pull in on demand.
            let closedIds = (try? await HermesLiveChat.shared.conversations())
                .map { Self.closedConversationIds($0, activeId: activeId) } ?? []
            if let id = activeId {
                let messages = try await HermesLiveChat.shared.history(conversationId: id)
                await MainActor.run { messages.forEach(addMessage) }
            }
            // Render the prefetched welcome whenever there is no active
            // conversation — first visit, or the previous one is closed.
            // Closed-conversation history is collapsed behind the toggle; the
            // new chat starts with its greeting on top.
            if activeId == nil {
                await loadWelcome()
            }
            await MainActor.run {
                historyConversationIds = closedIds
                refreshHistoryToggle()
            }
        } catch {
            await MainActor.run { addSystem("初始化会话失败") }
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
        guard !isSending && !isUploadingImage else { return }
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
            await ensureSession()
            do {
                let messages = try await HermesLiveChat.shared.sendTextMessages(text)
                await MainActor.run {
                    removePendingBubble()
                    messages.forEach(addMessage)
                }
            } catch {
                await MainActor.run {
                    removePendingBubble()
                    input.text = text
                    addSystem("发送失败")
                }
            }
        }
    }

    @objc private func attachTapped() {
        guard !isSending && !isUploadingImage else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = ["public.image"]
        picker.delegate = self
        present(picker, animated: true)
    }

    private func sendImage(_ image: UIImage) {
        guard !isUploadingImage else { return }
        guard let data = image.jpegData(compressionQuality: 0.88) else {
            addSystem("读取图片失败")
            return
        }
        guard data.count > 0, data.count <= Self.maxImageBytes else {
            addSystem("图片不能超过 10MB")
            return
        }
        isUploadingImage = true
        Task {
            defer {
                Task { @MainActor in
                    self.isUploadingImage = false
                }
            }
            await ensureSession()
            do {
                let messages = try await HermesLiveChat.shared.sendImageMessages(
                    data: data,
                    mimeType: "image/jpeg",
                    filename: "image_\(Int(Date().timeIntervalSince1970)).jpg"
                )
                await MainActor.run { messages.forEach(addMessage) }
            } catch {
                await MainActor.run { addSystem("图片发送失败") }
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
        let busy = isLoadingInitialState || isSending || isUploadingImage
        input.isEnabled = !busy
        attachButton.isEnabled = !busy
        sendButton.isEnabled = !busy && hasText
        sendButton.setTitle(isLoadingInitialState ? "加载中" : isUploadingImage ? "上传中" : isSending ? "发送中" : "发送", for: .normal)
    }

    @objc private func inputChanged() {
        updateComposerState()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func addSystem(_ text: String) {
        addBubble(text, mine: false, createdAt: nil)
    }

    private func addSystemOnce(_ text: String) {
        guard shownEventErrorMessages.insert(text).inserted else { return }
        addSystem(text)
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
        welcomePlaceholder = addBubble(text, mine: false, createdAt: nil)
    }

    private func removeWelcomePlaceholder() {
        guard let view = welcomePlaceholder else { return }
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        welcomePlaceholder = nil
    }

    // showPendingBubble renders the visitor's outgoing text optimistically while
    // the send is in flight. It is appended after the welcome placeholder, so the
    // greeting stays on top; removePendingBubble clears it before the server's
    // ordered [welcome, visitor] messages are added, which keeps the welcome
    // above the confirmed message instead of being re-appended below it.
    private func showPendingBubble(_ text: String) {
        removePendingBubble()
        pendingBubble = addBubble(text, mine: true, createdAt: nil)
    }

    private func removePendingBubble() {
        guard let view = pendingBubble else { return }
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        pendingBubble = nil
    }

    // refreshHistoryToggle shows or hides the "view earlier messages" bar at the
    // top of the list. It appears only while there is unloaded closed history.
    private func refreshHistoryToggle() {
        let shouldShow = !historyConversationIds.isEmpty && !historyExpanded
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
        button.setTitleColor(.secondaryLabel, for: .normal)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        button.addTarget(self, action: #selector(historyToggleTapped), for: .touchUpInside)
        return button
    }

    @objc private func historyToggleTapped() {
        Task { await loadHistory() }
    }

    // loadHistory pulls in earlier closed-conversation messages on demand and
    // reveals them while keeping the visitor's view anchored: prepending older
    // messages above the viewport would otherwise yank the scroll position, so we
    // offset by the height that appears. The fetch runs once; failures reset so
    // the visitor can retry by tapping the bar again.
    private func loadHistory() async {
        guard !historyExpanded, !historyLoading, !historyConversationIds.isEmpty else { return }
        historyLoading = true
        await MainActor.run { refreshHistoryToggle() }
        do {
            var loaded: [Message] = []
            for conversationId in historyConversationIds {
                loaded += try await HermesLiveChat.shared.conversationMessages(conversationId: conversationId)
            }
            await MainActor.run {
                historyExpanded = true
                prependHistory(loaded)
            }
        } catch {
            await MainActor.run { addSystem("加载更早消息失败") }
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
            let row = makeMessageRow(message, mine: message.senderType == "visitor")
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

    private func addMessage(_ message: Message) {
        if let key = messageKey(message), !messageKeys.insert(key).inserted {
            return
        }
        if message.contentType == "welcome" {
            hasPersistedWelcome = true
            removeWelcomePlaceholder()
        }
        addBubble(message, mine: message.senderType == "visitor")
        markMessageReadIfNeeded(message)
    }

    private func markMessageReadIfNeeded(_ message: Message) {
        guard message.senderType != "visitor" else { return }
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
                    self?.readMarkedMessageIds.remove(messageId)
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
        let bubble = makeBubbleView(text: text, mine: mine)
        let column = makeBubbleColumn(mine: mine, bubble: bubble, createdAt: createdAt)
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        stack.addArrangedSubview(row)
        activateBubbleConstraints(row: row, column: column, bubble: bubble, mine: mine)
        scrollToBottom()
        return row
    }

    @discardableResult
    private func addBubble(_ message: Message, mine: Bool) -> UIView {
        let row = makeMessageRow(message, mine: mine)
        stack.addArrangedSubview(row)
        scrollToBottom()
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

    private func makeBubbleView(text: String, mine: Bool) -> UIView {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byWordWrapping
        label.textColor = mine ? .white : .label
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = mine ? .systemBlue : .secondarySystemBackground
        bubble.layer.cornerRadius = 17
        bubble.layer.masksToBounds = true
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

    private func makeMessageBubbleView(_ message: Message, mine: Bool) -> UIView {
        if message.contentType == "image", let url = message.content["url"] as? String, !url.isEmpty {
            return makeImageBubbleView(url: url, mine: mine)
        }
        return makeBubbleView(text: message.displayText, mine: mine)
    }

    private func makeImageBubbleView(url: String, mine: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = mine ? .systemBlue : .secondarySystemBackground
        container.layer.cornerRadius = 17
        container.layer.masksToBounds = true

        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .tertiarySystemFill
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
        time.textColor = .secondaryLabel
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
            dot.backgroundColor = .secondaryLabel
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
