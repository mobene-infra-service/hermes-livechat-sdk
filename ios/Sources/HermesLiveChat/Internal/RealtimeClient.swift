import Foundation
import SwiftCentrifuge

internal final class RealtimeClient: CentrifugeClientDelegate {
    private var client: CentrifugeClient?
    private let emit: (HermesLiveChatEvent) -> Void
    private let onPublicationReceived: ([String: Any]) -> Void

    init(
        emit: @escaping (HermesLiveChatEvent) -> Void,
        onPublication: @escaping ([String: Any]) -> Void
    ) {
        self.emit = emit
        self.onPublicationReceived = onPublication
    }

    func connect(url: URL, token: String) {
        disconnect()
        let config = CentrifugeClientConfig(token: token)
        let client = CentrifugeClient(endpoint: url.absoluteString, config: config, delegate: self)
        self.client = client
        client.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        emit(.connectionStateChanged(.idle))
    }

    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        emit(.connectionStateChanged(.connecting))
    }

    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        emit(.connectionStateChanged(.connected))
    }

    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        emit(.connectionStateChanged(.disconnected))
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
        guard let json = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any] else { return }
        onPublicationReceived(json)
    }

    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        emit(.error(HermesLiveChatException(error: .unknown, code: nil, message: "\(event.error)", status: nil)))
    }
}
