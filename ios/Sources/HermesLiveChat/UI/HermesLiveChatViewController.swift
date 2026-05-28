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
    private var composerBottomConstraint: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var messageKeys = Set<String>()
    private var readMarkedMessageIds = Set<String>()
    private var started = false
    private var eventsTask: Task<Void, Never>?
    private var welcomePlaceholder: UIView?
    private var hasPersistedWelcome = false
    private static let bubbleMaxWidthRatio: CGFloat = 0.78
    private static let bubbleMaxWidthCap: CGFloat = 520

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
        Task {
            if startSessionOnOpen {
                await ensureSession()
            }
            if !startSessionOnOpen || !started {
                await loadWelcome()
            }
        }
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
        installLayoutConstraints()
    }

    private func configureScroll() {
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
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
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let send = UIButton(type: .system)
        send.setTitle("发送", for: .normal)
        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        composer.axis = .horizontal
        composer.spacing = 8
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.addArrangedSubview(input)
        composer.addArrangedSubview(send)
        view.addSubview(composer)
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
            bottom,
        ])
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
                        addSystem(error.message ?? "\(error.error)")
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
            if let id = HermesLiveChat.shared.currentConversationId {
                let messages = try await HermesLiveChat.shared.history(conversationId: id)
                await MainActor.run { messages.forEach(addMessage) }
            }
        } catch {
            await MainActor.run { addSystem("初始化会话失败") }
        }
    }

    @objc private func sendTapped() {
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        input.text = ""
        Task {
            await ensureSession()
            do {
                let messages = try await HermesLiveChat.shared.sendTextMessages(text)
                await MainActor.run { messages.forEach(addMessage) }
            } catch {
                await MainActor.run {
                    input.text = text
                    addSystem("发送失败")
                }
            }
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func addSystem(_ text: String) {
        addBubble(text, mine: false, createdAt: nil)
    }

    private func showWelcomePlaceholder(_ text: String) {
        guard !hasPersistedWelcome else { return }
        guard messageKeys.isEmpty else { return }
        guard welcomePlaceholder == nil else { return }
        welcomePlaceholder = addBubble(text, mine: false, createdAt: nil)
    }

    private func removeWelcomePlaceholder() {
        guard let view = welcomePlaceholder else { return }
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        welcomePlaceholder = nil
    }

    private func addMessage(_ message: Message) {
        if let key = messageKey(message), !messageKeys.insert(key).inserted {
            return
        }
        if message.contentType == "welcome" {
            hasPersistedWelcome = true
            removeWelcomePlaceholder()
        }
        addBubble(message.displayText, mine: message.senderType == "visitor", createdAt: message.createdAt)
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
