import Foundation

enum SampleConfig {
    struct Environment {
        let name: String
        let description: String
        let baseUrl: String
        let realtimeUrl: String
        let appKey: String
        let secretKey: String
    }

    static let environments: [Environment] = [
        Environment(
            name: "测试",
            description: "hermes-test.financifyx.com",
            baseUrl: "https://hermes-test.financifyx.com/api",
            realtimeUrl: "wss://hermes-test.financifyx.com/api/connection/websocket",
            appKey: "app_019e6335c04478838ef4f9418263d279",
            secretKey: "sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg"
        ),
        Environment(
            name: "生产",
            description: "hermesomni.com",
            baseUrl: "https://hermesomni.com/api",
            realtimeUrl: "wss://hermesomni.com/api/connection/websocket",
            appKey: "app_019e6335c04478838ef4f9418263d279",
            secretKey: "sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg"
        ),
    ]

    static let defaultEnvironmentIndex = 0

    static func randomCustomerId() -> String {
        "ios-demo-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
