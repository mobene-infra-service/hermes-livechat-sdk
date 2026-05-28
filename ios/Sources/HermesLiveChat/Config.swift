import Foundation

public struct HermesLiveChatConfig {
    public let baseUrl: URL
    public let appKey: String
    public let realtimeUrl: URL
    public let refreshLeewaySeconds: TimeInterval
    public let realtimeIdleDisconnectDelay: TimeInterval

    public init(
        baseUrl: URL,
        appKey: String,
        realtimeUrl: URL? = nil,
        refreshLeewaySeconds: TimeInterval = 60,
        realtimeIdleDisconnectDelay: TimeInterval = 5 * 60
    ) {
        self.baseUrl = baseUrl
        self.appKey = appKey
        self.realtimeUrl = realtimeUrl ?? HermesLiveChatConfig.deriveRealtimeUrl(baseUrl)
        self.refreshLeewaySeconds = refreshLeewaySeconds
        self.realtimeIdleDisconnectDelay = realtimeIdleDisconnectDelay
    }

    private static func deriveRealtimeUrl(_ baseUrl: URL) -> URL {
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/connection/websocket"
        components.query = nil
        return components.url!
    }
}
