import Foundation

public enum HermesLiveChatError: Error {
    case notConfigured
    case network
    case badRequest
    case tokenInvalid
    case tokenExpired
    case invalidVisitorId
    case conversationForbidden
    case conversationClosed
    case messageRateLimited
    case contentInvalid
    case attachmentTooLarge
    case attachmentTypeInvalid
    case channelDisabled
    case domainNotAllowed
    case orgDisabled
    case appInitTokenInvalid
    case appInitTokenExpired
    case realtimeConnectUnauthorized
    case realtimeProviderUnavailable
    case unknown
}

public struct HermesLiveChatException: Error {
    public let error: HermesLiveChatError
    public let code: String?
    public let message: String?
    public let status: Int?
}

internal func mapBackendError(status: Int, code: String?) -> HermesLiveChatError {
    switch code {
    case "70001": return .badRequest
    case "70002", "LC_TOKEN_INVALID": return .tokenInvalid
    case "70003", "LC_TOKEN_EXPIRED": return .tokenExpired
    case "70004", "LC_INVALID_VISITOR_ID": return .invalidVisitorId
    case "70024", "LC_CONV_FORBIDDEN": return .conversationForbidden
    case "70025", "LC_CONV_CLOSED": return .conversationClosed
    case "LC_MESSAGE_RATE_LIMITED": return .messageRateLimited
    case "LC_CONTENT_INVALID": return .contentInvalid
    case "70030", "LC_ATTACHMENT_TOO_LARGE": return .attachmentTooLarge
    case "70031", "LC_ATTACHMENT_TYPE_INVALID", "LC_ATTACHMENT_TYPE_NOT_ALLOWED": return .attachmentTypeInvalid
    case "70011", "LC_CHANNEL_DISABLED": return .channelDisabled
    case "70012", "LC_DOMAIN_NOT_ALLOWED": return .domainNotAllowed
    case "70010", "LC_ORG_LIVECHAT_DISABLED": return .orgDisabled
    case "70006", "LC_APP_INIT_TOKEN_INVALID": return .appInitTokenInvalid
    case "70007", "LC_APP_INIT_TOKEN_EXPIRED": return .appInitTokenExpired
    case "LC_REALTIME_CONNECT_UNAUTHORIZED": return .realtimeConnectUnauthorized
    case "70050", "LC_REALTIME_PROVIDER_UNAVAILABLE": return .realtimeProviderUnavailable
    default:
        if status == 400 { return .badRequest }
        if status == 401 { return .tokenInvalid }
        if status == 403 { return .conversationForbidden }
        if status >= 500 { return .realtimeProviderUnavailable }
        return .unknown
    }
}
