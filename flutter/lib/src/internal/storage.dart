import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persisted snapshot of the visitor session.
///
/// Stored in platform secure storage (iOS Keychain / Android Keystore).
/// The fields here are the minimum needed to silently renew after app
/// restart; messages and conversation list are never cached.
class StoredSession {
  StoredSession({
    required this.appKey,
    required this.visitorId,
    required this.contactId,
    required this.token,
    required this.tokenExp,
    this.realtimeUrl,
    this.lastConversationId,
    this.identityKey,
  });

  final String appKey;
  final String visitorId;
  final int contactId;
  final String token;
  final int tokenExp;
  final String? realtimeUrl;
  final String? lastConversationId;
  final String? identityKey;

  Map<String, Object?> toJson() => {
        'app_key': appKey,
        'visitor_id': visitorId,
        'contact_id': contactId,
        'token': token,
        'token_exp': tokenExp,
        if (realtimeUrl != null) 'realtime_url': realtimeUrl,
        if (lastConversationId != null)
          'last_conversation_id': lastConversationId,
        if (identityKey != null) 'identity_key': identityKey,
      };

  factory StoredSession.fromJson(Map<String, Object?> json) {
    return StoredSession(
      appKey: json['app_key'] as String,
      visitorId: json['visitor_id'] as String,
      contactId: (json['contact_id'] as num).toInt(),
      token: json['token'] as String,
      tokenExp: (json['token_exp'] as num).toInt(),
      realtimeUrl: json['realtime_url'] as String?,
      lastConversationId: json['last_conversation_id'] as String?,
      identityKey: json['identity_key'] as String?,
    );
  }
}

class SessionStore {
  SessionStore({
    FlutterSecureStorage? backend,
    this.namespace = 'hermes_livechat',
    this.scope = '',
  }) : _backend = backend ?? const FlutterSecureStorage();

  final FlutterSecureStorage _backend;
  final String namespace;

  // Sessions are scoped to the server that issued them: the same appKey on a
  // different baseUrl is a different backend with its own visitor token and
  // realtime URL, so reusing a cached session across servers would silently
  // talk to the old one. Set to the active baseUrl and folded into the key.
  final String scope;

  String _keyFor(String appKey) => '$namespace:$scope|$appKey';

  Future<StoredSession?> load(String appKey) async {
    final raw = await _backend.read(key: _keyFor(appKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      return StoredSession.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(StoredSession session) {
    return _backend.write(
      key: _keyFor(session.appKey),
      value: jsonEncode(session.toJson()),
    );
  }

  Future<void> clear(String appKey) => _backend.delete(key: _keyFor(appKey));
}
