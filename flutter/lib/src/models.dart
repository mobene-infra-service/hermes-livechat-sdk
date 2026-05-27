/// DTOs returned by `internal/livechat/http.go`.
///
/// Field names match the backend JSON exactly. Unknown fields are ignored.
class Conversation {
  const Conversation({
    required this.uuid,
    required this.status,
    required this.channelType,
    required this.channelId,
    this.assigneeType,
    this.assigneeCode,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCountVisitor = 0,
    this.createdAt,
    this.closedBy,
  });

  final String uuid;
  final String status;
  final String? assigneeType;
  final String? assigneeCode;
  final String channelType;
  final String channelId;
  final int? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCountVisitor;
  final int? createdAt;
  final String? closedBy;

  factory Conversation.fromJson(Map<String, Object?> json) {
    return Conversation(
      uuid: json['uuid'] as String,
      status: json['status'] as String,
      assigneeType: json['assignee_type'] as String?,
      assigneeCode: json['assignee_code'] as String?,
      channelType: json['channel_type'] as String,
      channelId: json['channel_id'] as String,
      lastMessageAt: _asInt(json['last_message_at']),
      lastMessagePreview: json['last_message_preview'] as String?,
      unreadCountVisitor: _asInt(json['unread_count_visitor']) ?? 0,
      createdAt: _asInt(json['created_at']),
      closedBy: json['closed_by'] as String?,
    );
  }
}

class Message {
  const Message({
    required this.uuid,
    required this.conversationId,
    required this.clientMsgId,
    required this.senderType,
    required this.senderId,
    required this.contentType,
    required this.content,
    required this.createdAt,
    this.status,
    this.readAt,
  });

  final String uuid;
  final String conversationId;
  final String clientMsgId;

  /// `visitor` / `bot` / `system` / (P1) `agent`
  final String senderType;
  final String senderId;

  /// `text` / `image` / `file` / `welcome` / `close`
  final String contentType;
  final Map<String, Object?> content;
  final String? status;
  final int? readAt;
  final int createdAt;

  factory Message.fromJson(Map<String, Object?> json) {
    return Message(
      uuid: json['uuid'] as String,
      conversationId: (json['conversation_id'] ?? '').toString(),
      clientMsgId: (json['client_msg_id'] ?? '') as String,
      senderType: json['sender_type'] as String,
      senderId: json['sender_id'] as String,
      contentType: json['content_type'] as String,
      content: Map<String, Object?>.from(json['content'] as Map),
      status: json['status'] as String?,
      readAt: _asInt(json['read_at']),
      createdAt: _asInt(json['created_at']) ?? 0,
    );
  }
}

class ConversationEvent {
  const ConversationEvent({
    required this.eventType,
    required this.createdAt,
    this.fromStatus,
    this.toStatus,
    this.actorType,
    this.actorId,
    this.payload,
  });

  final String eventType;
  final int createdAt;
  final String? fromStatus;
  final String? toStatus;
  final String? actorType;
  final String? actorId;
  final Map<String, Object?>? payload;

  factory ConversationEvent.fromJson(Map<String, Object?> json) {
    return ConversationEvent(
      eventType: json['event_type'] as String,
      fromStatus: json['from_status'] as String?,
      toStatus: json['to_status'] as String?,
      actorType: json['actor_type'] as String?,
      actorId: json['actor_id'] as String?,
      payload: json['payload'] is Map
          ? Map<String, Object?>.from(json['payload'] as Map)
          : null,
      createdAt: _asInt(json['created_at']) ?? 0,
    );
  }
}

/// Centrifugo publication envelope as defined in design §5.3.
class Publication {
  const Publication({
    required this.type,
    this.version = 1,
    this.eventId,
    this.orgCode,
    this.conversation,
    this.message,
    this.event,
    this.readMessageId,
    this.readAt,
    this.readerType,
    this.readerId,
  });

  final int version;
  final String type;
  final String? eventId;
  final String? orgCode;
  final Conversation? conversation;
  final Message? message;
  final ConversationEvent? event;

  // Used only when type == 'livechat.message.read'.
  final String? readMessageId;
  final int? readAt;
  final String? readerType;
  final String? readerId;

  factory Publication.fromJson(Map<String, Object?> json) {
    final messageJson = json['message'];
    final conversationJson = json['conversation'];
    final eventJson = json['event'];
    Message? msg;
    String? readMsgId;
    int? readAt;
    String? readerType;
    String? readerId;
    if (messageJson is Map) {
      final m = Map<String, Object?>.from(messageJson);
      readMsgId = m['uuid'] as String?;
      readAt = _asInt(m['read_at']);
      readerType = m['reader_type'] as String?;
      readerId = m['reader_id'] as String?;
      if (m['client_msg_id'] != null || m['content_type'] != null) {
        // It's a real message envelope, not the bare read receipt shape.
        msg = Message.fromJson(m);
      }
    }
    return Publication(
      version: _asInt(json['v']) ?? 1,
      type: json['type'] as String,
      eventId: json['event_id'] as String?,
      orgCode: json['org_code'] as String?,
      conversation: conversationJson is Map
          ? Conversation.fromJson(Map<String, Object?>.from(conversationJson))
          : null,
      message: msg,
      event: eventJson is Map
          ? ConversationEvent.fromJson(Map<String, Object?>.from(eventJson))
          : null,
      readMessageId: readMsgId,
      readAt: readAt,
      readerType: readerType,
      readerId: readerId,
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
