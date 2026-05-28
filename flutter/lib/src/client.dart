import 'dart:async';

import 'config.dart';
import 'errors.dart';
import 'internal/session.dart';
import 'models.dart';
import 'public_types.dart';

/// Singleton facade for visitor-side LiveChat operations.
///
/// Usage:
/// ```dart
/// HermesLiveChat.instance.configure(HermesLiveChatConfig(...));
/// final welcome = await HermesLiveChat.instance.prefetchWelcome();
/// final session = await HermesLiveChat.instance.startSession(VisitorIdentity(...));
/// await HermesLiveChat.instance.sendText('hello');
/// HermesLiveChat.instance.events.listen(handle);
/// ```
class HermesLiveChat {
  HermesLiveChat._();

  static final HermesLiveChat instance = HermesLiveChat._();

  Session? _session;

  /// Initialise the SDK. Call once during app startup.
  void configure(HermesLiveChatConfig config) {
    _session?.destroy();
    _session = Session(config: config)..bindLifecycle();
  }

  Stream<HermesLiveChatEvent> get events => _require().events;

  String? get currentConversationId => _require().currentConversationId;

  Future<String> prefetchWelcome({String? locale}) =>
      _require().prefetchWelcome(locale: locale);

  Future<VisitorSession> startSession(VisitorIdentity identity) =>
      _require().startSession(identity);

  Future<Message> sendText(String text, {String? conversationId}) =>
      _require().sendText(text, conversationId: conversationId);

  Future<List<Message>> sendTextMessages(
    String text, {
    String? conversationId,
  }) =>
      _require().sendTextMessages(text, conversationId: conversationId);

  Future<Message> sendImage({
    required List<int> bytes,
    required String mimeType,
    String? filename,
    String? conversationId,
  }) =>
      _require().sendImage(
        bytes: bytes,
        mimeType: mimeType,
        filename: filename,
        conversationId: conversationId,
      );

  Future<List<Message>> sendImageMessages({
    required List<int> bytes,
    required String mimeType,
    String? filename,
    String? conversationId,
  }) =>
      _require().sendImageMessages(
        bytes: bytes,
        mimeType: mimeType,
        filename: filename,
        conversationId: conversationId,
      );

  Future<void> markRead({
    required String messageId,
    required String conversationId,
  }) =>
      _require().markRead(messageId: messageId, conversationId: conversationId);

  Future<List<Message>> history({
    required String conversationId,
    String? afterId,
    int limit = 50,
  }) =>
      _require().history(
        conversationId: conversationId,
        afterId: afterId,
        limit: limit,
      );

  Future<void> disconnect() => _require().disconnect();

  Future<void> destroy() async {
    final session = _session;
    _session = null;
    await session?.destroy();
  }

  Session _require() {
    final session = _session;
    if (session == null) {
      throw const HermesLiveChatException(
        HermesLiveChatError.notConfigured,
        message: 'HermesLiveChat.configure() must be called before use',
      );
    }
    return session;
  }
}
