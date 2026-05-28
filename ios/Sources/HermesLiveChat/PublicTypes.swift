import Foundation

public struct VisitorIdentity: Codable {
    public var customerId: String?
    public var externalUserId: String?
    public var businessId: String?
    public var ticketId: String?
    public var number: String?
    public var email: String?
    public var name: String?
    public var avatar: String?
    public var locale: String?
    public var attrs: [String: String]?
    public var identityToken: String?

    public init(
        customerId: String? = nil,
        externalUserId: String? = nil,
        businessId: String? = nil,
        ticketId: String? = nil,
        number: String? = nil,
        email: String? = nil,
        name: String? = nil,
        avatar: String? = nil,
        locale: String? = nil,
        attrs: [String: String]? = nil,
        identityToken: String? = nil
    ) {
        self.customerId = customerId
        self.externalUserId = externalUserId
        self.businessId = businessId
        self.ticketId = ticketId
        self.number = number
        self.email = email
        self.name = name
        self.avatar = avatar
        self.locale = locale
        self.attrs = attrs
        self.identityToken = identityToken
    }
}

public struct VisitorSession {
    public let visitorId: String
    public let contactId: Int
    public let tokenExp: Int
    public let realtimeUrl: URL
}

public enum LiveChatConnectionState {
    case idle
    case connecting
    case connected
    case disconnected
}
