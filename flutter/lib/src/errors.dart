/// Error taxonomy mirroring `docs/design/livechat-protocol.md` §10
/// and design doc §16.
enum HermesLiveChatError {
  notConfigured,
  network,
  badRequest,

  // Visitor token
  tokenInvalid,
  tokenExpired,
  invalidVisitorId,

  // Conversation / message
  conversationForbidden,
  conversationClosed,
  messageRateLimited,
  contentInvalid,
  attachmentTooLarge,
  attachmentTypeInvalid,

  // Channel / org
  channelDisabled,
  domainNotAllowed,
  orgDisabled,

  // P1/P0.5 strong identity mode
  appInitTokenInvalid,
  appInitTokenExpired,

  // Realtime
  realtimeConnectUnauthorized,
  realtimeProviderUnavailable,

  unknown,
}

class HermesLiveChatException implements Exception {
  const HermesLiveChatException(
    this.error, {
    this.code,
    this.message,
    this.status,
  });

  final HermesLiveChatError error;
  final String? code;
  final String? message;
  final int? status;

  factory HermesLiveChatException.fromBackend({
    required int status,
    String? code,
    String? message,
  }) {
    return HermesLiveChatException(
      _mapBackendCode(status, code),
      code: code,
      message: message,
      status: status,
    );
  }

  @override
  String toString() =>
      'HermesLiveChatException($error, code=$code, status=$status, message=$message)';
}

HermesLiveChatError _mapBackendCode(int status, String? code) {
  switch (code) {
    case '70001':
      return HermesLiveChatError.badRequest;
    case '70002':
    case 'LC_TOKEN_INVALID':
      return HermesLiveChatError.tokenInvalid;
    case '70003':
    case 'LC_TOKEN_EXPIRED':
      return HermesLiveChatError.tokenExpired;
    case '70004':
    case 'LC_INVALID_VISITOR_ID':
      return HermesLiveChatError.invalidVisitorId;
    case '70024':
    case 'LC_CONV_FORBIDDEN':
      return HermesLiveChatError.conversationForbidden;
    case '70025':
    case 'LC_CONV_CLOSED':
      return HermesLiveChatError.conversationClosed;
    case 'LC_MESSAGE_RATE_LIMITED':
      return HermesLiveChatError.messageRateLimited;
    case 'LC_CONTENT_INVALID':
      return HermesLiveChatError.contentInvalid;
    case '70030':
    case 'LC_ATTACHMENT_TOO_LARGE':
      return HermesLiveChatError.attachmentTooLarge;
    case '70031':
    case 'LC_ATTACHMENT_TYPE_INVALID':
    case 'LC_ATTACHMENT_TYPE_NOT_ALLOWED':
      return HermesLiveChatError.attachmentTypeInvalid;
    case '70011':
    case 'LC_CHANNEL_DISABLED':
      return HermesLiveChatError.channelDisabled;
    case '70012':
    case 'LC_DOMAIN_NOT_ALLOWED':
      return HermesLiveChatError.domainNotAllowed;
    case '70010':
    case 'LC_ORG_LIVECHAT_DISABLED':
      return HermesLiveChatError.orgDisabled;
    case '70006':
    case 'LC_APP_INIT_TOKEN_INVALID':
      return HermesLiveChatError.appInitTokenInvalid;
    case '70007':
    case 'LC_APP_INIT_TOKEN_EXPIRED':
      return HermesLiveChatError.appInitTokenExpired;
    case 'LC_REALTIME_CONNECT_UNAUTHORIZED':
      return HermesLiveChatError.realtimeConnectUnauthorized;
    case '70050':
    case 'LC_REALTIME_PROVIDER_UNAVAILABLE':
      return HermesLiveChatError.realtimeProviderUnavailable;
  }
  if (status == 400) return HermesLiveChatError.badRequest;
  if (status == 401) return HermesLiveChatError.tokenInvalid;
  if (status == 403) return HermesLiveChatError.conversationForbidden;
  if (status >= 500) return HermesLiveChatError.realtimeProviderUnavailable;
  return HermesLiveChatError.unknown;
}
