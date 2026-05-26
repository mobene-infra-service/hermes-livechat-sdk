import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/src/models.dart';

void main() {
  group('Conversation.fromJson', () {
    test('parses a bot-handled assignment', () {
      final conv = Conversation.fromJson({
        'uuid': 'conv_1',
        'status': 'assigned',
        'assignee_type': 'bot',
        'assignee_code': 'bot_xxx',
        'channel_type': 'app',
        'channel_id': 'app_xxx',
        'last_message_at': 1778668800,
        'last_message_preview': 'hello',
        'unread_count_visitor': 2,
        'created_at': 1778668700,
      });
      expect(conv.uuid, 'conv_1');
      expect(conv.status, 'assigned');
      expect(conv.assigneeType, 'bot');
      expect(conv.assigneeCode, 'bot_xxx');
      expect(conv.channelType, 'app');
      expect(conv.channelId, 'app_xxx');
      expect(conv.lastMessageAt, 1778668800);
      expect(conv.unreadCountVisitor, 2);
    });

    test('handles closed conversation with null assignee', () {
      final conv = Conversation.fromJson({
        'uuid': 'conv_2',
        'status': 'closed',
        'channel_type': 'app',
        'channel_id': 'app_xxx',
        'closed_by': 'bot',
      });
      expect(conv.status, 'closed');
      expect(conv.assigneeType, isNull);
      expect(conv.assigneeCode, isNull);
      expect(conv.closedBy, 'bot');
      expect(conv.unreadCountVisitor, 0);
    });
  });

  group('Message.fromJson', () {
    test('parses a visitor text message', () {
      final msg = Message.fromJson({
        'uuid': 'msg_1',
        'conversation_id': 'conv_1',
        'client_msg_id': 'c_abc',
        'sender_type': 'visitor',
        'sender_id': 'v_1',
        'content_type': 'text',
        'content': {'text': 'hello'},
        'status': 'sent',
        'created_at': 1778668800,
      });
      expect(msg.uuid, 'msg_1');
      expect(msg.senderType, 'visitor');
      expect(msg.contentType, 'text');
      expect(msg.content['text'], 'hello');
      expect(msg.createdAt, 1778668800);
    });

    test('parses a bot image message', () {
      final msg = Message.fromJson({
        'uuid': 'msg_2',
        'conversation_id': 'conv_1',
        'client_msg_id': '',
        'sender_type': 'bot',
        'sender_id': 'bot_x',
        'content_type': 'image',
        'content': {
          'url': 'https://cdn.example.com/x.jpg',
          'mime_type': 'image/jpeg',
        },
        'created_at': 1778668900,
      });
      expect(msg.senderType, 'bot');
      expect(msg.contentType, 'image');
      expect(msg.content['url'], 'https://cdn.example.com/x.jpg');
    });
  });

  group('Publication.fromJson', () {
    test('parses livechat.message.created envelope', () {
      final pub = Publication.fromJson({
        'v': 1,
        'type': 'livechat.message.created',
        'event_id': 'evt_1',
        'org_code': 'ORG001',
        'conversation': {
          'uuid': 'conv_1',
          'status': 'assigned',
          'assignee_type': 'bot',
          'assignee_code': 'bot_x',
          'channel_type': 'app',
          'channel_id': 'app_xxx',
        },
        'message': {
          'uuid': 'msg_1',
          'conversation_id': 'conv_1',
          'client_msg_id': 'c_1',
          'sender_type': 'bot',
          'sender_id': 'bot_x',
          'content_type': 'text',
          'content': {'text': 'hello'},
          'created_at': 1778668800,
        },
      });
      expect(pub.type, 'livechat.message.created');
      expect(pub.eventId, 'evt_1');
      expect(pub.conversation?.uuid, 'conv_1');
      expect(pub.message?.uuid, 'msg_1');
      expect(pub.message?.content['text'], 'hello');
    });

    test('parses livechat.conversation.updated envelope', () {
      final pub = Publication.fromJson({
        'v': 1,
        'type': 'livechat.conversation.updated',
        'event_id': 'evt_2',
        'conversation': {
          'uuid': 'conv_1',
          'status': 'closed',
          'channel_type': 'app',
          'channel_id': 'app_xxx',
          'closed_by': 'bot',
        },
        'event': {
          'event_type': 'closed',
          'actor_type': 'bot',
          'actor_id': 'bot_x',
          'created_at': 1778668900,
        },
      });
      expect(pub.type, 'livechat.conversation.updated');
      expect(pub.conversation?.status, 'closed');
      expect(pub.event?.eventType, 'closed');
      expect(pub.event?.actorType, 'bot');
    });

    test('parses livechat.message.read envelope', () {
      final pub = Publication.fromJson({
        'v': 1,
        'type': 'livechat.message.read',
        'event_id': 'evt_3',
        'conversation': {
          'uuid': 'conv_1',
          'status': 'assigned',
          'channel_type': 'app',
          'channel_id': 'app_xxx',
        },
        'message': {
          'uuid': 'msg_1',
          'read_at': 1778669000,
          'reader_type': 'agent',
          'reader_id': 'AC_1',
        },
      });
      expect(pub.type, 'livechat.message.read');
      expect(pub.readMessageId, 'msg_1');
      expect(pub.readAt, 1778669000);
      expect(pub.readerType, 'agent');
      // Bare read receipt should not be parsed as a Message.
      expect(pub.message, isNull);
    });
  });
}
