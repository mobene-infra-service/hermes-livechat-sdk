import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/hermes_livechat.dart';

void main() {
  group('HermesLiveChatConfig', () {
    test('derives wss realtime URL from https baseUrl when omitted', () {
      final config = HermesLiveChatConfig(
        baseUrl: 'https://chat.example.com',
        appKey: 'app_x',
      );
      expect(config.realtimeUrl, 'wss://chat.example.com/connection/websocket');
    });

    test('derives ws realtime URL from http baseUrl', () {
      final config = HermesLiveChatConfig(
        baseUrl: 'http://localhost:8080',
        appKey: 'app_x',
      );
      expect(config.realtimeUrl, 'ws://localhost:8080/connection/websocket');
    });

    test('uses provided realtimeUrl override verbatim', () {
      final config = HermesLiveChatConfig(
        baseUrl: 'https://chat.example.com',
        appKey: 'app_x',
        realtimeUrl: 'wss://realtime.example.com/ws',
      );
      expect(config.realtimeUrl, 'wss://realtime.example.com/ws');
    });

    test('normalises baseUrl trailing slash', () {
      final config = HermesLiveChatConfig(
        baseUrl: 'https://chat.example.com/',
        appKey: 'app_x',
      );
      expect(config.normalizedBaseUrl, 'https://chat.example.com');
    });
  });
}
