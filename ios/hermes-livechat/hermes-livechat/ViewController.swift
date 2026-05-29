import CryptoKit
import HermesLiveChat
import UIKit

final class ViewController: UIViewController {
    private let environmentControl = UISegmentedControl(items: SampleConfig.environments.map(\.name))
    private let environmentDescriptionLabel = UILabel()
    private let baseUrlLabel = UILabel()
    private let realtimeUrlLabel = UILabel()
    private let appKeyLabel = UILabel()
    private let secretLabel = UILabel()
    private let customerIdInput = UITextField()
    private let openButton = UIButton(type: .system)
    private let customButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private var currentConfig = SampleConfig.environments[SampleConfig.defaultEnvironmentIndex]
    private var isOpening = false {
        didSet { updateLoadingState() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "hermes-livechat"
        view.backgroundColor = .systemGroupedBackground
        buildUI()
        applyConfig(currentConfig)
    }

    private func buildUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let titleLabel = UILabel()
        titleLabel.text = "Hermes LiveChat"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.numberOfLines = 0
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "选择测试或生产环境即可打开客服；也可以进入自定义配置手动填写地址和 App 信息。"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        stack.addArrangedSubview(subtitleLabel)

        environmentControl.selectedSegmentIndex = SampleConfig.defaultEnvironmentIndex
        environmentControl.addTarget(self, action: #selector(environmentChanged), for: .valueChanged)
        customButton.setTitle("自定义配置", for: .normal)
        customButton.addTarget(self, action: #selector(customConfigTapped), for: .touchUpInside)

        let environmentStack = UIStackView(arrangedSubviews: [
            environmentControl,
            customButton,
            environmentDescriptionLabel,
        ])
        environmentStack.axis = .vertical
        environmentStack.spacing = 12
        stack.addArrangedSubview(section(title: "环境", content: [environmentStack]))

        stack.addArrangedSubview(section(title: "当前配置", content: [
            infoRow(title: "Base URL", valueLabel: baseUrlLabel),
            infoRow(title: "Realtime", valueLabel: realtimeUrlLabel),
            infoRow(title: "App Key", valueLabel: appKeyLabel),
            infoRow(title: "Secret", valueLabel: secretLabel),
        ]))

        configureCustomerIdField()
        let randomButton = UIButton(type: .system)
        randomButton.setTitle("随机生成", for: .normal)
        randomButton.addTarget(self, action: #selector(randomCustomerTapped), for: .touchUpInside)

        let customerRow = UIStackView(arrangedSubviews: [customerIdInput, randomButton])
        customerRow.axis = .horizontal
        customerRow.alignment = .fill
        customerRow.spacing = 10
        customerIdInput.setContentHuggingPriority(.defaultLow, for: .horizontal)
        randomButton.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(section(title: "访客", content: [customerRow]))

        openButton.setTitle("打开客服", for: .normal)
        openButton.setTitleColor(.white, for: .normal)
        openButton.backgroundColor = .systemBlue
        openButton.layer.cornerRadius = 10
        openButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.addTarget(self, action: #selector(openLiveChatButtonTapped), for: .touchUpInside)
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true

        loadingIndicator.hidesWhenStopped = true
        let actionRow = UIStackView(arrangedSubviews: [openButton, loadingIndicator])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12
        stack.addArrangedSubview(actionRow)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    private func configureCustomerIdField() {
        customerIdInput.placeholder = "customerId"
        customerIdInput.text = SampleConfig.randomCustomerId()
        customerIdInput.borderStyle = .roundedRect
        customerIdInput.clearButtonMode = .whileEditing
        customerIdInput.autocapitalizationType = .none
        customerIdInput.autocorrectionType = .no
        customerIdInput.keyboardType = .asciiCapable
        customerIdInput.returnKeyType = .done
        customerIdInput.delegate = self
        customerIdInput.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func section(title: String, content: [UIView]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label

        let contentStack = UIStackView(arrangedSubviews: content)
        contentStack.axis = .vertical
        contentStack.spacing = 12

        let stack = UIStackView(arrangedSubviews: [titleLabel, contentStack])
        stack.axis = .vertical
        stack.spacing = 10

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func infoRow(title: String, valueLabel: UILabel) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        valueLabel.font = .preferredFont(forTextStyle: .footnote)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 0
        valueLabel.textAlignment = .right

        let row = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func openLiveChat() {
        guard !isOpening else { return }
        view.endEditing(true)

        let baseUrl = currentConfig.baseUrl.trimmingTrailingSlash()
        let realtimeUrl = currentConfig.realtimeUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let appKey = currentConfig.appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = currentConfig.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerId = customerIdInput.trimmedText.isEmpty
            ? SampleConfig.randomCustomerId()
            : customerIdInput.trimmedText
        customerIdInput.text = customerId

        guard let base = parseHTTPURL(baseUrl) else {
            showError("Base URL 需要是有效的 http:// 或 https:// 地址")
            return
        }
        guard !appKey.isEmpty else {
            showError("App Key 不能为空")
            return
        }

        let realtime: URL?
        if realtimeUrl.isEmpty {
            realtime = nil
        } else if let parsed = parseWebSocketURL(realtimeUrl) {
            realtime = parsed
        } else {
            showError("Realtime URL 需要是有效的 ws:// 或 wss:// 地址")
            return
        }

        HermesLiveChat.shared.configure(
            HermesLiveChatConfig(
                baseUrl: base,
                appKey: appKey,
                realtimeUrl: realtime
            )
        )

        isOpening = true
        Task { @MainActor in
            let identityToken: String?
            do {
                identityToken = secret.isEmpty
                    ? nil
                    : try makeIdentityToken(secret: secret, appKey: appKey, customerId: customerId, name: "iOS Test")
            } catch {
                isOpening = false
                showError("identity_token 生成失败：\(error.localizedDescription)")
                return
            }

            HermesLiveChatLauncher.present(
                from: self,
                identity: VisitorIdentity(
                    customerId: customerId,
                    name: "iOS Test",
                    locale: "zh-CN",
                    identityToken: identityToken
                ),
                title: "在线客服",
                locale: "zh-CN",
                startSessionOnOpen: true
            )
            isOpening = false
        }
    }

    @objc private func openLiveChatButtonTapped() {
        openLiveChat()
    }

    @objc private func environmentChanged() {
        guard SampleConfig.environments.indices.contains(environmentControl.selectedSegmentIndex) else { return }
        applyConfig(SampleConfig.environments[environmentControl.selectedSegmentIndex])
    }

    @objc private func customConfigTapped() {
        let page = CustomConfigViewController(config: currentConfig)
        page.onSave = { [weak self] config in
            self?.environmentControl.selectedSegmentIndex = UISegmentedControl.noSegment
            self?.applyConfig(config)
        }
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private func randomCustomerTapped() {
        customerIdInput.text = SampleConfig.randomCustomerId()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func applyConfig(_ config: SampleConfig.Environment) {
        currentConfig = config
        environmentDescriptionLabel.text = "\(config.name) · \(config.description)"
        environmentDescriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        environmentDescriptionLabel.textColor = .secondaryLabel
        environmentDescriptionLabel.numberOfLines = 0
        baseUrlLabel.text = config.baseUrl
        realtimeUrlLabel.text = config.realtimeUrl.isEmpty ? "自动推导" : config.realtimeUrl
        appKeyLabel.text = config.appKey
        secretLabel.text = maskSecret(config.secretKey)
    }

    private func updateLoadingState() {
        openButton.isEnabled = !isOpening
        customButton.isEnabled = !isOpening
        environmentControl.isEnabled = !isOpening
        openButton.alpha = isOpening ? 0.7 : 1
        openButton.setTitle(isOpening ? "正在打开..." : "打开客服", for: .normal)
        isOpening ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
    }

    private func maskSecret(_ value: String) -> String {
        guard value.count > 10 else { return value.isEmpty ? "-" : value }
        return "\(value.prefix(6))...\(value.suffix(4))"
    }

    private func parseHTTPURL(_ raw: String) -> URL? {
        parseURL(raw, allowedSchemes: ["http", "https"])
    }

    private func parseWebSocketURL(_ raw: String) -> URL? {
        parseURL(raw, allowedSchemes: ["ws", "wss"])
    }

    private func parseURL(_ raw: String, allowedSchemes: Set<String>) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        return components.url
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "配置错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func makeIdentityToken(secret: String, appKey: String, customerId: String, name: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "aud": "livechat:init",
            "app_key": appKey,
            "sub": customerId,
            "customer_id": customerId,
            "name": name,
            "locale": "zh-CN",
            "iat": now,
            "exp": now + 5 * 60,
        ]
        let signingInput = [
            try base64URLJSON(header),
            try base64URLJSON(payload),
        ].joined(separator: ".")
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        return "\(signingInput).\(base64URLEncoded(Data(signature)))"
    }

    private func base64URLJSON(_ value: [String: Any]) throws -> String {
        base64URLEncoded(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    private func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class CustomConfigViewController: UIViewController {
    var onSave: ((SampleConfig.Environment) -> Void)?

    private let baseUrlInput = UITextField()
    private let realtimeUrlInput = UITextField()
    private let appKeyInput = UITextField()
    private let secretInput = UITextField()
    private let saveButton = UIButton(type: .system)

    private let initialConfig: SampleConfig.Environment

    init(config: SampleConfig.Environment) {
        self.initialConfig = config
        super.init(nibName: nil, bundle: nil)
        title = "自定义配置"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        buildUI()
    }

    private func buildUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        configureField(baseUrlInput, placeholder: "Base URL", value: initialConfig.baseUrl, keyboardType: .URL)
        configureField(realtimeUrlInput, placeholder: "Realtime URL（可留空自动推导）", value: initialConfig.realtimeUrl, keyboardType: .URL)
        configureField(appKeyInput, placeholder: "App Key", value: initialConfig.appKey)
        configureField(secretInput, placeholder: "Secret Key（可留空）", value: initialConfig.secretKey)

        stack.addArrangedSubview(labeledField("Base URL", field: baseUrlInput))
        stack.addArrangedSubview(labeledField("Realtime URL", field: realtimeUrlInput))
        stack.addArrangedSubview(labeledField("App Key", field: appKeyInput))
        stack.addArrangedSubview(labeledField("Secret Key", field: secretInput))

        saveButton.setTitle("保存并使用", for: .normal)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = .systemBlue
        saveButton.layer.cornerRadius = 10
        saveButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.addArrangedSubview(saveButton)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
            saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    private func configureField(_ field: UITextField, placeholder: String, value: String, keyboardType: UIKeyboardType = .asciiCapable) {
        field.placeholder = placeholder
        field.text = value
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = keyboardType
        field.returnKeyType = .next
        field.delegate = self
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func labeledField(_ title: String, field: UITextField) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)

        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    @objc private func saveTapped() {
        let baseUrl = baseUrlInput.trimmedText.trimmingTrailingSlash()
        let realtimeUrl = realtimeUrlInput.trimmedText
        let appKey = appKeyInput.trimmedText
        let secret = secretInput.trimmedText

        guard isValidURL(baseUrl, schemes: ["http", "https"]) else {
            showError("Base URL 需要是有效的 http:// 或 https:// 地址")
            return
        }
        guard realtimeUrl.isEmpty || isValidURL(realtimeUrl, schemes: ["ws", "wss"]) else {
            showError("Realtime URL 需要是有效的 ws:// 或 wss:// 地址")
            return
        }
        guard !appKey.isEmpty else {
            showError("App Key 不能为空")
            return
        }

        onSave?(
            SampleConfig.Environment(
                name: "自定义",
                description: baseUrl,
                baseUrl: baseUrl,
                realtimeUrl: realtimeUrl,
                appKey: appKey,
                secretKey: secret
            )
        )
        navigationController?.popViewController(animated: true)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func isValidURL(_ raw: String, schemes: Set<String>) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme),
              let host = components.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "配置错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

extension ViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension CustomConfigViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case baseUrlInput:
            realtimeUrlInput.becomeFirstResponder()
        case realtimeUrlInput:
            appKeyInput.becomeFirstResponder()
        case appKeyInput:
            secretInput.becomeFirstResponder()
        default:
            textField.resignFirstResponder()
        }
        return true
    }
}

private extension UITextField {
    var trimmedText: String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var value = self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
