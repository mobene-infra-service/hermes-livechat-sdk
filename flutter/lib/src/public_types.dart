// Public types for the Hermes LiveChat SDK.
//
// Kept in a separate file so consumers can `import 'hermes_livechat.dart'`
// and reference them without touching internals.
import 'models.dart';
import 'errors.dart';

/// Visitor identity passed to [HermesLiveChat.startSession].
///
/// Fields map to backend `contactAttrs` in `internal/livechat/service.go`.
class VisitorIdentity {
  const VisitorIdentity({
    this.customerId,
    this.externalUserId,
    this.businessId,
    this.ticketId,
    this.number,
    this.email,
    this.name,
    this.avatar,
    this.locale,
    this.attrs,
    this.identityToken,
  });

  final String? customerId;
  final String? externalUserId;
  final String? businessId;
  final String? ticketId;
  final String? number;
  final String? email;
  final String? name;
  final String? avatar;
  final String? locale;
  final Map<String, Object?>? attrs;
  final String? identityToken;
}

/// Snapshot returned by [HermesLiveChat.startSession].
class VisitorSession {
  const VisitorSession({
    required this.visitorId,
    required this.contactId,
    required this.tokenExp,
    required this.realtimeUrl,
  });

  final String visitorId;
  final int contactId;
  final int tokenExp;
  final String realtimeUrl;
}

enum ConnectionState { idle, connecting, connected, disconnected }

/// Events emitted on [HermesLiveChat.events].
sealed class HermesLiveChatEvent {
  const HermesLiveChatEvent();
}

class ConnectionStateChanged extends HermesLiveChatEvent {
  const ConnectionStateChanged(this.state);
  final ConnectionState state;
}

class MessageReceived extends HermesLiveChatEvent {
  const MessageReceived({required this.message, required this.conversation});
  final Message message;
  final Conversation conversation;
}

class ConversationUpdated extends HermesLiveChatEvent {
  const ConversationUpdated({required this.conversation, this.event});
  final Conversation conversation;
  final ConversationEvent? event;
}

class MessageRead extends HermesLiveChatEvent {
  const MessageRead({
    required this.conversationId,
    required this.messageId,
    required this.readAt,
    this.readerType,
  });
  final String conversationId;
  final String messageId;
  final int readAt;
  final String? readerType;
}

class HermesError extends HermesLiveChatEvent {
  const HermesError(this.error);
  final HermesLiveChatException error;
}
