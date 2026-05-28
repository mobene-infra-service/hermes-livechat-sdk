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
  Timer? _realtimeIdleTimer;

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
    if (json['welcome'] is String) {
      return json['welcome'] as String;
    }
    final cfg = json['config'];
    if (cfg is Map && cfg['welcome'] is String) {
      return cfg['welcome'] as String;
    }
    return '';
  }

  Future<VisitorSession> startSession(VisitorIdentity identity) async {
    final cached = _stored ?? await store.load(config.appKey);
    _currentConversationId ??= cached?.lastConversationId;
    if (cached != null && !_isExpired(cached.tokenExp)) {
      _stored = cached;
      await _connectTransport(
        cached.realtimeUrl ?? config.realtimeUrl,
        cached.token,
      );
      return _visitorSession(cached);
    }

    final json = await api.init(
      identity: identity,
      oldVisitorToken: cached?.token,
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
    await _refreshCurrentConversation(token);

    await _connectTransport(realtimeUrl, token);
    return _visitorSession(_stored!);
  }

  Future<Message> sendText(String text, {String? conversationId}) async {
    final result = await _sendTextResult(text, conversationId: conversationId);
    return result.message;
  }

  Future<List<Message>> sendTextMessages(
    String text, {
    String? conversationId,
  }) async {
    final result = await _sendTextResult(text, conversationId: conversationId);
    return result.messages;
  }

  Future<SendMessageResult> _sendTextResult(
    String text, {
    String? conversationId,
  }) async {
    final token = await _validToken();
    final clientMsgId = newClientMsgId();
    final implicitConversation = conversationId == null;
    await _ensureRealtimeConnected(token);
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
    final result = await _sendImageResult(
      bytes: bytes,
      mimeType: mimeType,
      filename: filename,
      conversationId: conversationId,
    );
    return result.message;
  }

  Future<List<Message>> sendImageMessages({
    required List<int> bytes,
    required String mimeType,
    String? filename,
    String? conversationId,
  }) async {
    final result = await _sendImageResult(
      bytes: bytes,
      mimeType: mimeType,
      filename: filename,
      conversationId: conversationId,
    );
    return result.messages;
  }

  Future<SendMessageResult> _sendImageResult({
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
    await _ensureRealtimeConnected(token);
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
    return [...messages]..sort(_compareMessages);
  }

  Future<void> ensureConnected() async {
    final stored = _stored;
    if (stored == null) return;
    final token = await _validToken();
    await _connectTransport(_stored?.realtimeUrl ?? config.realtimeUrl, token);
  }

  Future<void> disconnect() async {
    _cancelRealtimeIdleTimer();
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
    _cancelRealtimeIdleTimer();
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
      _touchRealtimeActivity();
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
      _touchRealtimeActivity();
    } catch (_) {
      _transportUrl = null;
      _transportToken = null;
      _transportState = ConnectionState.idle;
      rethrow;
    }
  }

  void _onPublication(Publication pub) {
    _touchRealtimeActivity();
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

  Future<void> _ensureRealtimeConnected(String token) async {
    final stored = _stored;
    if (stored == null) return;
    await _connectTransport(stored.realtimeUrl ?? config.realtimeUrl, token);
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
    await _refreshCurrentConversation(token);
    await _connectTransport(realtimeUrl, token);
    return token;
  }

  Future<void> _refreshCurrentConversation(String token) async {
    try {
      final conversations = await api.listConversations(visitorToken: token);
      final active = conversations.where((item) => item.status != 'closed');
      if (active.isNotEmpty) {
        _rememberConversation(active.first.uuid);
      }
    } catch (_) {
      // Active conversation discovery is only needed for eager history restore;
      // sending still works because the backend reuses the active conversation.
    }
  }

  bool _isExpired(int exp) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp - now <= config.refreshLeewaySeconds;
  }

  VisitorSession _visitorSession(StoredSession session) {
    return VisitorSession(
      visitorId: session.visitorId,
      contactId: session.contactId,
      tokenExp: session.tokenExp,
      realtimeUrl: session.realtimeUrl ?? config.realtimeUrl,
    );
  }

  Future<SendMessageResult> _sendText(
    String token,
    String? conversationId,
    String text,
    String clientMsgId,
  ) async {
    final result = await api.sendText(
      visitorToken: token,
      conversationId: conversationId,
      text: text,
      clientMsgId: clientMsgId,
    );
    return _handleSendResult(result);
  }

  Future<SendMessageResult> _sendImage({
    required String token,
    required String? conversationId,
    required String key,
    required String downloadUrl,
    required String mimeType,
    required int size,
    required String clientMsgId,
  }) async {
    final result = await api.sendImage(
      visitorToken: token,
      conversationId: conversationId,
      key: key,
      url: downloadUrl,
      mimeType: mimeType,
      size: size,
      clientMsgId: clientMsgId,
    );
    return _handleSendResult(result);
  }

  SendMessageResult _handleSendResult(SendMessageResult result) {
    final conversation = result.conversation;
    if (conversation != null) {
      _rememberConversation(conversation.uuid);
    }
    for (final message in result.messages) {
      _dedup.add(message.uuid);
      _dedup.add(message.clientMsgId);
      if (message.uuid == result.message.uuid ||
          message.clientMsgId == result.message.clientMsgId) {
        continue;
      }
      if (conversation != null) {
        _events
            .add(MessageReceived(message: message, conversation: conversation));
      }
    }
    _dedup.add(result.message.uuid);
    _dedup.add(result.message.clientMsgId);
    _rememberConversation(result.message.conversationId);
    _touchRealtimeActivity();
    return result;
  }

  void _touchRealtimeActivity() {
    _realtimeIdleTimer?.cancel();
    final delay = config.realtimeIdleDisconnectDelay;
    if (delay <= Duration.zero) return;
    _realtimeIdleTimer = Timer(delay, () {
      _realtimeIdleTimer = null;
      unawaited(disconnect());
    });
  }

  void _cancelRealtimeIdleTimer() {
    _realtimeIdleTimer?.cancel();
    _realtimeIdleTimer = null;
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

int _compareMessages(Message a, Message b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  if (byTime != 0) return byTime;
  final byRank = _messageSortRank(a).compareTo(_messageSortRank(b));
  if (byRank != 0) return byRank;
  return a.uuid.compareTo(b.uuid);
}

int _messageSortRank(Message message) {
  if (message.contentType == 'welcome') return 0;
  if (message.contentType == 'close') return 2;
  return 1;
}
