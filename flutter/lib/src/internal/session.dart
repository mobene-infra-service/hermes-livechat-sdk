import 'dart:async';

import '../config.dart';
import '../errors.dart';
import '../models.dart';
import '../public_types.dart';
import 'api_client.dart';
import 'lifecycle.dart';
import 'realtime.dart';
import 'storage.dart';
import 'util.dart';

/// Owns visitor session state and orchestrates REST + realtime + lifecycle.
///
/// Not exposed to consumers — facade [HermesLiveChat] delegates to this.
class Session {
  Session({
    required this.config,
    ApiClient? api,
    RealtimeTransport? transport,
    SessionStore? store,
  })  : api = api ?? ApiClient(config),
        transport = transport ?? CentrifugeRealtime(),
        store = store ?? SessionStore();

  final HermesLiveChatConfig config;
  final ApiClient api;
  final RealtimeTransport transport;
  final SessionStore store;
  final DedupCache _dedup = DedupCache();

  final _events = StreamController<HermesLiveChatEvent>.broadcast();
  Stream<HermesLiveChatEvent> get events => _events.stream;

  StreamSubscription? _transportStateSub;
  StreamSubscription? _transportPubSub;
  AppLifecycleObserver? _lifecycle;

  StoredSession? _stored;
  String? _currentConversationId;
  String? _transportUrl;
  String? _transportToken;
  ConnectionState _transportState = ConnectionState.idle;
  String? get currentConversationId => _currentConversationId;

  void bindLifecycle() {
    _lifecycle ??= AppLifecycleObserver(
      backgroundDisconnectDelay: config.backgroundDisconnectDelay,
      onShouldDisconnect: () async {
        await disconnect();
      },
      onShouldReconnect: () async {
        if (_stored != null) await ensureConnected();
      },
    )..attach();
  }

  Future<String> prefetchWelcome({String? locale}) async {
    final json = await api.publicConfig(locale: locale);
    final cfg = json['config'];
    if (cfg is Map && cfg['welcome'] is String) {
      return cfg['welcome'] as String;
    }
    return '';
  }

  Future<VisitorSession> startSession(VisitorIdentity identity) async {
    final cached = await store.load(config.appKey);
    _currentConversationId = cached?.lastConversationId;
    final canReuse = cached != null && !_isExpired(cached.tokenExp);

    final json = await api.init(
      identity: identity,
      oldVisitorToken: canReuse ? cached.token : null,
    );

    final visitorId = json['visitor_id'] as String;
    final contactId = (json['contact_id'] as num).toInt();
    final token = json['token'] as String;
    final tokenExp = (json['token_exp'] as num).toInt();
    final realtime = json['realtime'];
    final realtimeUrl = (realtime is Map && realtime['url'] is String)
        ? realtime['url'] as String
        : config.realtimeUrl;

    _stored = StoredSession(
      appKey: config.appKey,
      visitorId: visitorId,
      contactId: contactId,
      token: token,
      tokenExp: tokenExp,
      realtimeUrl: realtimeUrl,
      lastConversationId: _currentConversationId,
    );
    await store.save(_stored!);

    await _connectTransport(realtimeUrl, token);
    return VisitorSession(
      visitorId: visitorId,
      contactId: contactId,
      tokenExp: tokenExp,
      realtimeUrl: realtimeUrl,
    );
  }

  Future<Message> sendText(String text, {String? conversationId}) async {
    final token = await _validToken();
    final clientMsgId = newClientMsgId();
    final implicitConversation = conversationId == null;
    final convId = conversationId ?? _currentConversationId;
    try {
      return await _sendText(token, convId, text, clientMsgId);
    } on HermesLiveChatException catch (error) {
      if (!implicitConversation ||
          error.error != HermesLiveChatError.conversationClosed) {
        rethrow;
      }
      _forgetCurrentConversation(convId);
      return _sendText(token, null, text, clientMsgId);
    }
  }

  Future<Message> sendImage({
    required List<int> bytes,
    required String mimeType,
    String? filename,
    String? conversationId,
  }) async {
    final token = await _validToken();
    final presign = await api.presignAttachment(
      visitorToken: token,
      filename: filename ?? defaultImageFilename(mimeType),
      mimeType: mimeType,
      size: bytes.length,
    );
    final uploadUrl = presign['upload_url'] as String;
    final method = (presign['method'] as String?) ?? 'PUT';
    final headers = (presign['headers'] is Map)
        ? Map<String, String>.from(presign['headers'] as Map)
        : <String, String>{};
    final key = presign['key'] as String;
    final downloadUrl = presign['download_url'] as String;
    await api.uploadPresignedUrl(
      url: uploadUrl,
      method: method,
      headers: headers,
      body: bytes,
    );
    final clientMsgId = newClientMsgId();
    final implicitConversation = conversationId == null;
    final convId = conversationId ?? _currentConversationId;
    try {
      return await _sendImage(
        token: token,
        conversationId: convId,
        key: key,
        downloadUrl: downloadUrl,
        mimeType: mimeType,
        size: bytes.length,
        clientMsgId: clientMsgId,
      );
    } on HermesLiveChatException catch (error) {
      if (!implicitConversation ||
          error.error != HermesLiveChatError.conversationClosed) {
        rethrow;
      }
      _forgetCurrentConversation(convId);
      return _sendImage(
        token: token,
        conversationId: null,
        key: key,
        downloadUrl: downloadUrl,
        mimeType: mimeType,
        size: bytes.length,
        clientMsgId: clientMsgId,
      );
    }
  }

  Future<void> markRead({
    required String messageId,
    required String conversationId,
  }) async {
    final token = await _validToken();
    await api.markRead(visitorToken: token, messageId: messageId);
    _rememberConversation(conversationId);
  }

  Future<List<Message>> history({
    required String conversationId,
    String? afterId,
    int limit = 50,
  }) async {
    final token = await _validToken();
    final messages = await api.listMessages(
      visitorToken: token,
      conversationId: conversationId,
      afterId: afterId,
      limit: limit,
    );
    _rememberConversation(conversationId);
    return messages;
  }

  Future<void> ensureConnected() async {
    final stored = _stored;
    if (stored == null) return;
    final token = await _validToken();
    await _connectTransport(_stored?.realtimeUrl ?? config.realtimeUrl, token);
  }

  Future<void> disconnect() async {
    _transportUrl = null;
    _transportToken = null;
    _transportState = ConnectionState.idle;
    await transport.disconnect();
  }

  Future<void> destroy() async {
    await _transportStateSub?.cancel();
    await _transportPubSub?.cancel();
    _lifecycle?.detach();
    _lifecycle = null;
    _transportUrl = null;
    _transportToken = null;
    _transportState = ConnectionState.idle;
    await transport.disconnect();
    await _events.close();
    api.close();
  }

  // ── internals ──────────────────────────────────────────────────────────

  Future<void> _connectTransport(String url, String token) async {
    if (_transportUrl == url &&
        _transportToken == token &&
        (_transportState == ConnectionState.connecting ||
            _transportState == ConnectionState.connected)) {
      return;
    }
    _transportUrl = null;
    _transportToken = null;
    _transportState = ConnectionState.connecting;
    await _transportStateSub?.cancel();
    await _transportPubSub?.cancel();
    _transportStateSub = transport.stateStream.listen((state) {
      _transportState = state;
      _events.add(ConnectionStateChanged(state));
    });
    _transportPubSub = transport.publicationStream.listen(_onPublication);
    try {
      await transport.connect(url: url, token: token);
      _transportUrl = url;
      _transportToken = token;
    } catch (_) {
      _transportUrl = null;
      _transportToken = null;
      _transportState = ConnectionState.idle;
      rethrow;
    }
  }

  void _onPublication(Publication pub) {
    if (!_dedup.add(pub.eventId)) return;
    switch (pub.type) {
      case 'livechat.message.created':
        if (pub.message != null) {
          if (!_dedup.add(pub.message!.uuid)) return;
          if (!_dedup.add(pub.message!.clientMsgId)) return;
          if (pub.conversation != null) {
            _rememberPublicationConversation(pub.conversation!);
            _events.add(
              MessageReceived(
                message: pub.message!,
                conversation: pub.conversation!,
              ),
            );
          }
        }
        break;
      case 'livechat.conversation.updated':
        if (pub.conversation != null) {
          _rememberPublicationConversation(pub.conversation!);
          _events.add(
            ConversationUpdated(
              conversation: pub.conversation!,
              event: pub.event,
            ),
          );
        }
        break;
      case 'livechat.message.read':
        if (pub.readMessageId != null && pub.conversation != null) {
          _events.add(
            MessageRead(
              conversationId: pub.conversation!.uuid,
              messageId: pub.readMessageId!,
              readAt: pub.readAt ?? 0,
              readerType: pub.readerType,
            ),
          );
        }
        break;
      default:
        // Unknown types are intentionally dropped.
        break;
    }
  }

  Future<String> _validToken() async {
    final stored = _stored ?? await store.load(config.appKey);
    if (stored == null) {
      throw const HermesLiveChatException(
        HermesLiveChatError.notConfigured,
        message: 'startSession() must be called before this operation',
      );
    }
    _stored = stored;
    _currentConversationId ??= stored.lastConversationId;
    if (!_isExpired(stored.tokenExp)) return stored.token;
    // Silent renewal: backend accepts an expired visitor token within the
    // configured renewal window.
    final renewed = await api.init(
      identity: const VisitorIdentity(),
      oldVisitorToken: stored.token,
    );
    final token = renewed['token'] as String;
    final exp = (renewed['token_exp'] as num).toInt();
    final realtime = renewed['realtime'];
    final realtimeUrl = (realtime is Map && realtime['url'] is String)
        ? realtime['url'] as String
        : stored.realtimeUrl ?? config.realtimeUrl;
    _stored = StoredSession(
      appKey: stored.appKey,
      visitorId: renewed['visitor_id'] as String,
      contactId: (renewed['contact_id'] as num).toInt(),
      token: token,
      tokenExp: exp,
      realtimeUrl: realtimeUrl,
      lastConversationId: stored.lastConversationId,
    );
    await store.save(_stored!);
    await _connectTransport(realtimeUrl, token);
    return token;
  }

  bool _isExpired(int exp) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp - now <= config.refreshLeewaySeconds;
  }

  Future<Message> _sendText(
    String token,
    String? conversationId,
    String text,
    String clientMsgId,
  ) async {
    final msg = await api.sendText(
      visitorToken: token,
      conversationId: conversationId,
      text: text,
      clientMsgId: clientMsgId,
    );
    _dedup.add(msg.clientMsgId);
    _dedup.add(msg.uuid);
    _rememberConversation(msg.conversationId);
    return msg;
  }

  Future<Message> _sendImage({
    required String token,
    required String? conversationId,
    required String key,
    required String downloadUrl,
    required String mimeType,
    required int size,
    required String clientMsgId,
  }) async {
    final msg = await api.sendImage(
      visitorToken: token,
      conversationId: conversationId,
      key: key,
      url: downloadUrl,
      mimeType: mimeType,
      size: size,
      clientMsgId: clientMsgId,
    );
    _dedup.add(msg.uuid);
    _dedup.add(msg.clientMsgId);
    _rememberConversation(msg.conversationId);
    return msg;
  }

  void _rememberPublicationConversation(Conversation conversation) {
    if (conversation.status == 'closed') {
      _forgetCurrentConversation(conversation.uuid);
      return;
    }
    _rememberConversation(conversation.uuid);
  }

  void _rememberConversation(String id) {
    if (id.isEmpty) return;
    if (_currentConversationId == id) return;
    _currentConversationId = id;
    final stored = _stored;
    if (stored != null) {
      _stored = StoredSession(
        appKey: stored.appKey,
        visitorId: stored.visitorId,
        contactId: stored.contactId,
        token: stored.token,
        tokenExp: stored.tokenExp,
        realtimeUrl: stored.realtimeUrl,
        lastConversationId: id,
      );
      store.save(_stored!);
    }
  }

  void _forgetCurrentConversation(String? id) {
    final shouldClear =
        id == null || id.isEmpty || _currentConversationId == id;
    if (shouldClear) {
      _currentConversationId = null;
    }
    final stored = _stored;
    if (stored != null) {
      _stored = StoredSession(
        appKey: stored.appKey,
        visitorId: stored.visitorId,
        contactId: stored.contactId,
        token: stored.token,
        tokenExp: stored.tokenExp,
        realtimeUrl: stored.realtimeUrl,
        lastConversationId: shouldClear ? null : stored.lastConversationId,
      );
      store.save(_stored!);
    }
  }
}
