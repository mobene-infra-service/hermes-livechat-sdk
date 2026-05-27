import HermesLiveChat
import UIKit

final class ViewController: UIViewController {
    private let baseUrlInput = UITextField()
    private let realtimeUrlInput = UITextField()
    private let appKeyInput = UITextField()
    private let customerIdInput = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "hermes-livechat"
        view.backgroundColor = .systemBackground
        buildUi()
    }

    private func buildUi() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let titleLabel = UILabel()
        titleLabel.text = "hermes-livechat"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        configureField(baseUrlInput, placeholder: "baseUrl", value: SampleConfig.defaultBaseUrl)
        configureField(realtimeUrlInput, placeholder: "realtimeUrl（留空由 SDK 从 baseUrl 自动推导）", value: SampleConfig.defaultRealtimeUrl)
        configureField(appKeyInput, placeholder: "appKey", value: SampleConfig.defaultAppKey)
        configureField(customerIdInput, placeholder: "customerId", value: SampleConfig.defaultCustomerId)

        stack.addArrangedSubview(baseUrlInput)
        stack.addArrangedSubview(realtimeUrlInput)
        stack.addArrangedSubview(appKeyInput)
        stack.addArrangedSubview(customerIdInput)

        var openConfig = UIButton.Configuration.filled()
        openConfig.title = "打开客服"
        openConfig.baseBackgroundColor = .systemBlue
        openConfig.baseForegroundColor = .white
        openConfig.cornerStyle = .medium
        openConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let openButton = UIButton(
            configuration: openConfig,
            primaryAction: UIAction { [weak self] _ in self?.openLiveChat() }
        )
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(openButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    private func configureField(_ field: UITextField, placeholder: String, value: String) {
        field.placeholder = placeholder
        field.text = value
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .URL
        field.returnKeyType = .next
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func openLiveChat() {
        view.endEditing(true)

        let baseUrl = baseUrlInput.trimmedText.trimmingTrailingSlash()
        let realtimeUrl = realtimeUrlInput.trimmedText
        let appKey = appKeyInput.trimmedText
        let customerId = customerIdInput.trimmedText.isEmpty
            ? SampleConfig.defaultCustomerId
            : customerIdInput.trimmedText

        guard let base = parseHTTPURL(baseUrl) else {
            showError("请填写有效的 baseUrl（http:// 或 https://，且包含 host）")
            return
        }
        guard !appKey.isEmpty else {
            showError("请填写 appKey")
            return
        }

        let realtime: URL?
        if realtimeUrl.isEmpty {
            realtime = nil
        } else if let parsed = parseWebSocketURL(realtimeUrl) {
            realtime = parsed
        } else {
            showError("realtimeUrl 必须是 ws:// 或 wss:// 且包含 host")
            return
        }

        HermesLiveChat.shared.configure(
            HermesLiveChatConfig(
                baseUrl: base,
                appKey: appKey,
                realtimeUrl: realtime
            )
        )

        HermesLiveChatLauncher.present(
            from: self,
            identity: VisitorIdentity(
                customerId: customerId,
                name: "iOS Test",
                locale: "zh-CN"
            ),
            title: "在线客服",
            locale: "zh-CN",
            startSessionOnOpen: true
        )
    }

    private func parseHTTPURL(_ raw: String) -> URL? {
        return parseURL(raw, allowedSchemes: ["http", "https"])
    }

    private func parseWebSocketURL(_ raw: String) -> URL? {
        return parseURL(raw, allowedSchemes: ["ws", "wss"])
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
