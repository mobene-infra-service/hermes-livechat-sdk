import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/hermes_livechat.dart';
import 'package:hermes_livechat/src/internal/api_client.dart';
import 'package:hermes_livechat/src/internal/realtime.dart';
import 'package:hermes_livechat/src/internal/session.dart';
import 'package:hermes_livechat/src/internal/storage.dart';

/// In-memory [SessionStore] that never touches platform secure storage.
class _MemoryStore extends SessionStore {
  _MemoryStore();

  StoredSession? _stored;

  @override
  Future<StoredSession?> load(String appKey) async => _stored;

  @override
  Future<void> save(StoredSession session) async {
    _stored = session;
  }

  @override
  Future<void> clear(String appKey) async {
    _stored = null;
  }
}

class _FakeTransport implements RealtimeTransport {
  final _state = StreamController<ConnectionState>.broadcast();
  final _publications = StreamController<Publication>.broadcast();

  bool connectCalled = false;
  int connectCalls = 0;
  String? lastUrl;
  String? lastToken;

  @override
  Stream<ConnectionState> get stateStream => _state.stream;

  @override
  Stream<Publication> get publicationStream => _publications.stream;

  @override
  Future<void> connect({required String url, required String token}) async {
    connectCalled = true;
    connectCalls += 1;
    lastUrl = url;
    lastToken = token;
    _state.add(ConnectionState.connecting);
    _state.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _state.add(ConnectionState.idle);
  }

  @override
  Future<void> setToken(String token) async {
    lastToken = token;
  }

  void emit(Publication pub) => _publications.add(pub);
}

class _FakeApi extends ApiClient {
  _FakeApi(super.config);

  int initCalls = 0;
  String? lastOldVisitorToken;
  String tokenValue = 'visitor_token_value';
  int tokenExp = 1778755200;
  int closedFailures = 0;
  String responseConversationId = 'conv_1';
  String responseRealtimeUrl = 'wss://chat.example.com/connection/websocket';
  final sentConversationIds = <String?>[];

  @override
  Future<Map<String, Object?>> init({
    required VisitorIdentity identity,
    String? oldVisitorToken,
  }) async {
    initCalls += 1;
    lastOldVisitorToken = oldVisitorToken;
    return {
      'visitor_id': 'v_1',
      'contact_id': 12345,
      'token': tokenValue,
      'token_exp': tokenExp,
      'realtime': {'url': responseRealtimeUrl},
    };
  }

  @override
  Future<Message> sendText({
    required String visitorToken,
    String? conversationId,
    required String text,
    required String clientMsgId,
  }) async {
    sentConversationIds.add(conversationId);
    if (closedFailures > 0) {
      closedFailures -= 1;
      throw const HermesLiveChatException(
        HermesLiveChatError.conversationClosed,
        code: 'LC_CONV_CLOSED',
        status: 409,
        message: 'conversation is closed',
      );
    }
    return Message(
      uuid: 'msg_${sentConversationIds.length}',
      conversationId: responseConversationId,
      clientMsgId: clientMsgId,
      senderType: 'visitor',
      senderId: 'v_1',
      contentType: 'text',
      content: {'text': text},
      createdAt: 1778668800 + sentConversationIds.length,
    );
  }
}

HermesLiveChatConfig _baseConfig() => HermesLiveChatConfig(
      baseUrl: 'https://chat.example.com',
      appKey: 'app_xxx',
    );

void main() {
  group('Session.startSession', () {
    test('starts with app_key only and connects realtime', () async {
      final config = _baseConfig();
      final api = _FakeApi(config);
      final transport = _FakeTransport();
      final session = Session(
        config: config,
        api: api,
        transport: transport,
        store: _MemoryStore(),
      );

      final result = await session.startSession(
        const VisitorIdentity(customerId: 'cust_1'),
      );

      expect(api.lastOldVisitorToken, isNull);
      expect(transport.connectCalled, isTrue);
      expect(transport.lastToken, 'visitor_token_value');
      expect(result.visitorId, 'v_1');
      expect(result.contactId, 12345);

      await session.destroy();
    });

    test('reuses cached visitor token when not expired', () async {
      final config = _baseConfig();
      final store = _MemoryStore();
      final future = DateTime.now()
              .add(const Duration(hours: 12))
              .millisecondsSinceEpoch ~/
          1000;
      await store.save(
        StoredSession(
          appKey: 'app_xxx',
          visitorId: 'v_1',
          contactId: 12345,
          token: 'cached_token',
          tokenExp: future,
          lastConversationId: 'conv_cached',
        ),
      );
      final api = _FakeApi(config);
      final transport = _FakeTransport();
      final session = Session(
        config: config,
        api: api,
        transport: transport,
        store: store,
      );

      await session.startSession(const VisitorIdentity());

      expect(api.lastOldVisitorToken, 'cached_token');
      expect(session.currentConversationId, 'conv_cached');

      await session.destroy();
    });
  });

  group('Session.sendText', () {
    test(
      'retries implicit cached conversation once when it is closed',
      () async {
        final future = DateTime.now()
                .add(const Duration(hours: 12))
                .millisecondsSinceEpoch ~/
            1000;
        final store = _MemoryStore();
        await store.save(
          StoredSession(
            appKey: 'app_xxx',
            visitorId: 'v_1',
            contactId: 12345,
            token: 'cached_token',
            tokenExp: future,
            lastConversationId: 'conv_old',
          ),
        );
        final config = _baseConfig();
        final api = _FakeApi(config)
          ..closedFailures = 1
          ..responseConversationId = 'conv_new';
        final session = Session(
          config: config,
          api: api,
          transport: _FakeTransport(),
          store: store,
        );
        await session.startSession(const VisitorIdentity());

        final message = await session.sendText('hello');

        expect(api.sentConversationIds, ['conv_old', null]);
        expect(message.conversationId, 'conv_new');
        expect(session.currentConversationId, 'conv_new');
        expect(store._stored?.lastConversationId, 'conv_new');

        await session.destroy();
      },
    );

    test('does not retry an explicit closed conversation', () async {
      final config = _baseConfig();
      final api = _FakeApi(config)..closedFailures = 1;
      final session = Session(
        config: config,
        api: api,
        transport: _FakeTransport(),
        store: _MemoryStore(),
      );
      await session.startSession(const VisitorIdentity());

      await expectLater(
        session.sendText('hello', conversationId: 'conv_closed'),
        throwsA(
          isA<HermesLiveChatException>().having(
            (error) => error.error,
            'error',
            HermesLiveChatError.conversationClosed,
          ),
        ),
      );
      expect(api.sentConversationIds, ['conv_closed']);

      await session.destroy();
    });

    test('reconnects realtime with renewed URL and token', () async {
      final past = DateTime.now()
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch ~/
          1000;
      final future = DateTime.now()
              .add(const Duration(hours: 12))
              .millisecondsSinceEpoch ~/
          1000;
      final store = _MemoryStore();
      await store.save(
        StoredSession(
          appKey: 'app_xxx',
          visitorId: 'v_1',
          contactId: 12345,
          token: 'old_token',
          tokenExp: past,
          realtimeUrl: 'wss://old.example.com/connection/websocket',
        ),
      );
      final config = _baseConfig();
      final api = _FakeApi(config)
        ..tokenValue = 'renewed_token'
        ..tokenExp = future
        ..responseRealtimeUrl = 'wss://new.example.com/connection/websocket';
      final transport = _FakeTransport();
      final session = Session(
        config: config,
        api: api,
        transport: transport,
        store: store,
      );

      await session.sendText('hello');

      expect(api.lastOldVisitorToken, 'old_token');
      expect(
        store._stored?.realtimeUrl,
        'wss://new.example.com/connection/websocket',
      );
      expect(transport.connectCalls, 1);
      expect(transport.lastUrl, 'wss://new.example.com/connection/websocket');
      expect(transport.lastToken, 'renewed_token');

      await session.destroy();
    });
  });

  group('Session realtime publications', () {
    late HermesLiveChatConfig config;
    late _FakeApi api;
    late _FakeTransport transport;
    late _MemoryStore store;
    late Session session;

    setUp(() async {
      config = _baseConfig();
      api = _FakeApi(config);
      transport = _FakeTransport();
      store = _MemoryStore();
      session = Session(
        config: config,
        api: api,
        transport: transport,
        store: store,
      );
      await session.startSession(const VisitorIdentity(customerId: 'cust_1'));
    });

    tearDown(() async {
      await session.destroy();
    });

    test('emits MessageReceived for livechat.message.created', () async {
      final completer = Completer<HermesLiveChatEvent>();
      session.events
          .firstWhere((e) => e is MessageReceived)
          .then(completer.complete);

      transport.emit(
        Publication.fromJson({
          'v': 1,
          'type': 'livechat.message.created',
          'event_id': 'evt_1',
          'conversation': {
            'uuid': 'conv_1',
            'status': 'assigned',
            'assignee_type': 'bot',
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
            'content': {'text': 'hi'},
            'created_at': 1778668800,
          },
        }),
      );

      final event = await completer.future.timeout(const Duration(seconds: 1))
          as MessageReceived;
      expect(event.message.uuid, 'msg_1');
      expect(event.conversation.uuid, 'conv_1');
      expect(session.currentConversationId, 'conv_1');
    });

    test('drops duplicate event_id', () async {
      final received = <HermesLiveChatEvent>[];
      final sub = session.events
          .where((e) => e is MessageReceived)
          .listen(received.add);

      Publication build() => Publication.fromJson({
            'v': 1,
            'type': 'livechat.message.created',
            'event_id': 'evt_dup',
            'conversation': {
              'uuid': 'conv_1',
              'status': 'assigned',
              'channel_type': 'app',
              'channel_id': 'app_xxx',
            },
            'message': {
              'uuid': 'msg_dup',
              'conversation_id': 'conv_1',
              'client_msg_id': 'c_dup',
              'sender_type': 'bot',
              'sender_id': 'bot_x',
              'content_type': 'text',
              'content': {'text': 'hi'},
              'created_at': 1778668800,
            },
          });

      transport.emit(build());
      transport.emit(build());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      await sub.cancel();
    });

    test(
      'emits ConversationUpdated for livechat.conversation.updated',
      () async {
        final completer = Completer<HermesLiveChatEvent>();
        session.events
            .firstWhere((e) => e is ConversationUpdated)
            .then(completer.complete);

        transport.emit(
          Publication.fromJson({
            'v': 1,
            'type': 'livechat.message.created',
            'event_id': 'evt_seed',
            'conversation': {
              'uuid': 'conv_1',
              'status': 'assigned',
              'channel_type': 'app',
              'channel_id': 'app_xxx',
            },
            'message': {
              'uuid': 'msg_seed',
              'conversation_id': 'conv_1',
              'client_msg_id': 'c_seed',
              'sender_type': 'bot',
              'sender_id': 'bot_x',
              'content_type': 'text',
              'content': {'text': 'hi'},
              'created_at': 1778668800,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(session.currentConversationId, 'conv_1');

        transport.emit(
          Publication.fromJson({
            'v': 1,
            'type': 'livechat.conversation.updated',
            'event_id': 'evt_close',
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
          }),
        );

        final event = await completer.future.timeout(const Duration(seconds: 1))
            as ConversationUpdated;
        expect(event.conversation.status, 'closed');
        expect(event.event?.eventType, 'closed');
        expect(session.currentConversationId, isNull);
        expect(store._stored?.lastConversationId, isNull);
      },
    );
  });
}
