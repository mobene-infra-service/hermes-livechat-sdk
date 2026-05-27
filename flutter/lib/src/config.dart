class HermesLiveChatConfig {
  HermesLiveChatConfig({
    required this.baseUrl,
    required this.appKey,
    String? realtimeUrl,
    this.refreshLeewaySeconds = 60,
    this.backgroundDisconnectDelay = const Duration(seconds: 30),
    this.realtimeIdleDisconnectDelay = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 10),
    this.logger,
  })  : realtimeUrl = realtimeUrl ?? _deriveRealtimeUrl(baseUrl),
        assert(baseUrl.startsWith('http'), 'baseUrl must be http(s)');

  /// e.g. `https://chat.example.com`. Trailing slash is stripped.
  final String baseUrl;

  /// `t_lc_app.app_key`. Sent in `/public-config` and `/init` as
  /// `channel_type=app & app_key=...`.
  final String appKey;

  /// Centrifugo WebSocket URL. If omitted, derived from [baseUrl]:
  /// `https://x` → `wss://x/connection/websocket`.
  final String realtimeUrl;

  /// Refresh the visitor token this many seconds before it expires.
  final int refreshLeewaySeconds;

  /// Wait this long after app backgrounding before tearing down the WS.
  /// Short flicker (e.g. system biometric prompt) won't disconnect.
  final Duration backgroundDisconnectDelay;

  /// Tear down the WS after this much time without message send/receive
  /// activity. The visitor session and active conversation are retained.
  final Duration realtimeIdleDisconnectDelay;

  final Duration requestTimeout;

  /// Optional sink for SDK diagnostic messages. Tokens are always redacted
  /// before being passed in.
  final void Function(String message)? logger;

  String get normalizedBaseUrl => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
}

String _deriveRealtimeUrl(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: '/connection/websocket',
  ).toString();
}
