import HermesLiveChat
import UIKit

final class ViewController: UIViewController {
    private let baseUrlInput = UITextField()
    private let realtimeUrlInput = UITextField()
    private let appKeyInput = UITextField()
    private let customerIdInput = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Hermes LiveChat Test"
        view.backgroundColor = .systemBackground
        buildUi()
    }

    private func buildUi() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let titleLabel = UILabel()
        titleLabel.text = "Hermes LiveChat Test"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        configureField(baseUrlInput, placeholder: "baseUrl", value: SampleConfig.defaultBaseUrl)
        configureField(realtimeUrlInput, placeholder: "realtimeUrl", value: SampleConfig.defaultRealtimeUrl)
        configureField(appKeyInput, placeholder: "appKey", value: SampleConfig.defaultAppKey)
        configureField(customerIdInput, placeholder: "customerId", value: SampleConfig.defaultCustomerId)

        stack.addArrangedSubview(baseUrlInput)
        stack.addArrangedSubview(realtimeUrlInput)
        stack.addArrangedSubview(appKeyInput)
        stack.addArrangedSubview(customerIdInput)

        let openButton = UIButton(type: .system)
        openButton.setTitle("打开客服", for: .normal)
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.addTarget(self, action: #selector(openLiveChat), for: .touchUpInside)
        openButton.backgroundColor = .systemBlue
        openButton.tintColor = .white
        openButton.layer.cornerRadius = 8
        openButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
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

    @objc private func openLiveChat() {
        view.endEditing(true)

        let baseUrl = baseUrlInput.trimmedText.trimmingTrailingSlash()
        let realtimeUrl = realtimeUrlInput.trimmedText
        let appKey = appKeyInput.trimmedText
        let customerId = customerIdInput.trimmedText.isEmpty
            ? SampleConfig.defaultCustomerId
            : customerIdInput.trimmedText

        guard let base = URL(string: baseUrl), !appKey.isEmpty else {
            showError("请填写有效的 baseUrl 和 appKey")
            return
        }

        let realtime = realtimeUrl.isEmpty ? nil : URL(string: realtimeUrl)
        if !realtimeUrl.isEmpty, realtime == nil {
            showError("请填写有效的 realtimeUrl")
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
