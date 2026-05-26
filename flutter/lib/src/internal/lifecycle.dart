import 'dart:async';

import 'package:flutter/widgets.dart';

/// Hooks into Flutter's lifecycle to drive realtime disconnect/reconnect.
///
/// Behaviour (design §10.2):
/// - `paused` (app backgrounded) starts a timer. If still backgrounded after
///   [backgroundDisconnectDelay], the SDK disconnects. Short flickers (e.g.
///   system biometric prompt) don't drop the WS.
/// - `resumed` cancels the timer and asks for an immediate reconnect.
class AppLifecycleObserver with WidgetsBindingObserver {
  AppLifecycleObserver({
    required this.onShouldDisconnect,
    required this.onShouldReconnect,
    this.backgroundDisconnectDelay = const Duration(seconds: 30),
  });

  final Future<void> Function() onShouldDisconnect;
  final Future<void> Function() onShouldReconnect;
  final Duration backgroundDisconnectDelay;

  Timer? _bgTimer;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    WidgetsBinding.instance.removeObserver(this);
    _bgTimer?.cancel();
    _bgTimer = null;
    _attached = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _bgTimer?.cancel();
        _bgTimer = Timer(backgroundDisconnectDelay, () {
          onShouldDisconnect();
        });
        break;
      case AppLifecycleState.resumed:
        _bgTimer?.cancel();
        _bgTimer = null;
        onShouldReconnect();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // No-op. `inactive` is a brief transition (e.g. control center pull),
        // and `detached` means the engine is going away.
        break;
    }
  }
}
