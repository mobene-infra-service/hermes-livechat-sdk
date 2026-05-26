import 'dart:async';
import 'dart:convert';

import 'package:centrifuge/centrifuge.dart' as cent;

import '../models.dart';
import '../public_types.dart';

/// Abstract transport so callers can swap the realtime implementation
/// (e.g. for tests or alternative networks) without touching the facade.
abstract class RealtimeTransport {
  Stream<ConnectionState> get stateStream;
  Stream<Publication> get publicationStream;

  Future<void> connect({required String url, required String token});
  Future<void> disconnect();
  Future<void> setToken(String token);
}

/// Default implementation backed by
/// [centrifuge-dart](https://pub.dev/packages/centrifuge) ≥ 0.19.0.
///
/// Server-side subscriptions are driven entirely by the visitor token's
/// `subs` claim, so the SDK never calls `subscribe`. Publications arrive
/// on [cent.Client.publication] as [cent.ServerPublicationEvent], with
/// `data` carrying the bytes of the JSON envelope from design §5.3.
class CentrifugeRealtime implements RealtimeTransport {
  CentrifugeRealtime();

  cent.Client? _client;
  final _state = StreamController<ConnectionState>.broadcast();
  final _publications = StreamController<Publication>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  Stream<ConnectionState> get stateStream => _state.stream;

  @override
  Stream<Publication> get publicationStream => _publications.stream;

  @override
  Future<void> connect({required String url, required String token}) async {
    await disconnect();
    final client = cent.createClient(url, cent.ClientConfig(token: token));
    _client = client;

    _subs.add(
      client.connecting.listen((_) {
        _state.add(ConnectionState.connecting);
      }),
    );
    _subs.add(
      client.connected.listen((_) {
        _state.add(ConnectionState.connected);
      }),
    );
    _subs.add(
      client.disconnected.listen((_) {
        _state.add(ConnectionState.disconnected);
      }),
    );
    _subs.add(
      client.publication.listen((cent.ServerPublicationEvent evt) {
        final pub = _decodePublication(evt.data);
        if (pub != null) _publications.add(pub);
      }),
    );

    await client.connect();
  }

  @override
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (client != null) {
      try {
        await client.disconnect();
      } catch (_) {
        // Best-effort teardown.
      }
    }
    _state.add(ConnectionState.idle);
  }

  @override
  Future<void> setToken(String token) async {
    _client?.setToken(token);
  }
}

Publication? _decodePublication(List<int> bytes) {
  if (bytes.isEmpty) return null;
  try {
    final raw = utf8.decode(bytes, allowMalformed: true);
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    return Publication.fromJson(Map<String, Object?>.from(json));
  } catch (_) {
    // Malformed publications are dropped on the floor — the SDK relies on
    // REST replay for correctness, not on every publication landing.
    return null;
  }
}
