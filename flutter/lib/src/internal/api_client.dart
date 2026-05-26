import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../errors.dart';
import '../models.dart';
import '../public_types.dart';
import 'util.dart';

/// Thin REST client for `/api/livechat/v1/*`.
///
/// Only knows about HTTP shape; session state (current visitor token, last
/// conversation, etc.) lives in `Session`.
class ApiClient {
  ApiClient(this._config, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final HermesLiveChatConfig _config;
  final http.Client _http;

  Future<Map<String, Object?>> publicConfig({String? locale}) {
    return _get(
      '/api/livechat/v1/public-config',
      query: {
        'channel_type': 'app',
        'app_key': _config.appKey,
        if (locale != null) 'locale': locale,
      },
    );
  }

  /// Calls `POST /api/livechat/v1/init` for the App channel.
  ///
  /// [oldVisitorToken] enables silent renewal — the backend prefers it when
  /// present and valid.
  Future<Map<String, Object?>> init({
    required VisitorIdentity identity,
    String? oldVisitorToken,
  }) {
    return _post(
      '/api/livechat/v1/init',
      body: {
        'channel_type': 'app',
        'app_key': _config.appKey,
        if (identity.customerId != null) 'customer_id': identity.customerId,
        if (identity.externalUserId != null)
          'external_user_id': identity.externalUserId,
        if (identity.businessId != null) 'business_id': identity.businessId,
        if (identity.ticketId != null) 'ticket_id': identity.ticketId,
        if (identity.number != null) 'number': identity.number,
        'user': {
          if (identity.email != null) 'email': identity.email,
          if (identity.name != null) 'name': identity.name,
          if (identity.avatar != null) 'avatar': identity.avatar,
        },
        if (identity.locale != null) 'locale': identity.locale,
        if (identity.attrs != null) 'attrs': identity.attrs,
      },
      bearerToken: oldVisitorToken,
    );
  }

  Future<Message> sendText({
    required String visitorToken,
    String? conversationId,
    required String text,
    required String clientMsgId,
  }) async {
    final json = await _post(
      '/api/livechat/v1/messages',
      bearerToken: visitorToken,
      body: {
        if (conversationId != null) 'conversation_id': conversationId,
        'client_msg_id': clientMsgId,
        'content_type': 'text',
        'content': {'text': text},
      },
    );
    return Message.fromJson(_messageEnvelope(json));
  }

  Future<Message> sendImage({
    required String visitorToken,
    String? conversationId,
    required String key,
    required String url,
    required String mimeType,
    required int size,
    required String clientMsgId,
  }) async {
    final json = await _post(
      '/api/livechat/v1/messages',
      bearerToken: visitorToken,
      body: {
        if (conversationId != null) 'conversation_id': conversationId,
        'client_msg_id': clientMsgId,
        'content_type': 'image',
        'content': {'key': key, 'url': url, 'mime': mimeType, 'size': size},
      },
    );
    return Message.fromJson(_messageEnvelope(json));
  }

  Future<void> markRead({
    required String visitorToken,
    required String messageId,
  }) {
    return _post(
      '/api/livechat/v1/messages/${Uri.encodeComponent(messageId)}/read',
      bearerToken: visitorToken,
    );
  }

  Future<List<Message>> listMessages({
    required String visitorToken,
    required String conversationId,
    String? afterId,
    String? cursor,
    int limit = 80,
  }) async {
    final json = await _get(
      '/api/livechat/v1/conversations/${Uri.encodeComponent(conversationId)}/messages',
      bearerToken: visitorToken,
      query: {
        if (afterId != null) 'after_id': afterId,
        if (cursor != null) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    final items = (json['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => Message.fromJson(Map<String, Object?>.from(e)))
        .toList(growable: false);
  }

  Future<Map<String, Object?>> presignAttachment({
    required String visitorToken,
    required String filename,
    required String mimeType,
    required int size,
  }) {
    return _post(
      '/api/livechat/v1/attachments/presign',
      bearerToken: visitorToken,
      body: {'filename': filename, 'mime': mimeType, 'size': size},
    );
  }

  Future<void> uploadPresignedUrl({
    required String url,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final response = await _http
        .send(
          http.Request(method, Uri.parse(url))
            ..headers.addAll(headers)
            ..bodyBytes = body,
        )
        .timeout(_config.requestTimeout);
    if (response.statusCode >= 300) {
      throw HermesLiveChatException(
        HermesLiveChatError.attachmentTypeInvalid,
        status: response.statusCode,
        message: 'attachment upload failed',
      );
    }
  }

  void close() => _http.close();

  // ── internals ──────────────────────────────────────────────────────────

  Map<String, Object?> _messageEnvelope(Map<String, Object?> json) {
    final inner = json['message'];
    if (inner is Map) return Map<String, Object?>.from(inner);
    return json;
  }

  Future<Map<String, Object?>> _get(
    String path, {
    Map<String, String>? query,
    String? bearerToken,
  }) async {
    final uri = Uri.parse(
      _config.normalizedBaseUrl + path,
    ).replace(queryParameters: query);
    final response = await _http
        .get(uri, headers: _headers(bearerToken))
        .timeout(_config.requestTimeout);
    return _decode(response);
  }

  Future<Map<String, Object?>> _post(
    String path, {
    Object? body,
    String? bearerToken,
  }) async {
    final uri = Uri.parse(_config.normalizedBaseUrl + path);
    final response = await _http
        .post(
          uri,
          headers: _headers(bearerToken, hasBody: body != null),
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(_config.requestTimeout);
    return _decode(response);
  }

  Map<String, String> _headers(String? bearerToken, {bool hasBody = false}) {
    final headers = {'Accept': 'application/json'};
    if (hasBody) headers['Content-Type'] = 'application/json';
    if (bearerToken != null) headers['Authorization'] = 'Bearer $bearerToken';
    return headers;
  }

  Map<String, Object?> _decode(http.Response response) {
    if (response.statusCode == 204) return const <String, Object?>{};
    Map<String, Object?>? payload;
    try {
      if (response.body.isNotEmpty) {
        payload = Map<String, Object?>.from(jsonDecode(response.body) as Map);
      }
    } catch (_) {
      // Fall through to error mapping below.
    }

    final code = _backendCode(payload);
    final legacyCode = payload?['error_code']?.toString();
    final message = payload?['msg'] as String? ?? response.reasonPhrase;
    final isHTTPError = response.statusCode < 200 || response.statusCode >= 300;
    final isBusinessError = code != null && code != 0;
    if (isHTTPError || isBusinessError) {
      final logger = _config.logger;
      if (logger != null) {
        logger(
          'livechat REST ${response.statusCode} ${code ?? ''} ${Logger.redact(message)}',
        );
      }
      throw HermesLiveChatException.fromBackend(
        status: response.statusCode,
        code: code?.toString() ?? legacyCode,
        message: message,
      );
    }

    if (payload == null) {
      return const <String, Object?>{};
    }
    if (_isArkeEnvelope(payload)) {
      final data = payload['data'];
      if (data is Map) return Map<String, Object?>.from(data);
      return const <String, Object?>{};
    }
    return payload;
  }

  bool _isArkeEnvelope(Map<String, Object?> payload) {
    return payload.containsKey('code') &&
        payload.containsKey('msg') &&
        payload.containsKey('data');
  }

  int? _backendCode(Map<String, Object?>? payload) {
    final raw = payload?['code'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}
