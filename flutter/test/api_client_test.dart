import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/hermes_livechat.dart';
import 'package:hermes_livechat/src/internal/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HermesLiveChatConfig _config() => HermesLiveChatConfig(
      baseUrl: 'https://chat.example.com',
      appKey: 'app_xxx',
    );

void main() {
  group('ApiClient.publicConfig', () {
    test('issues GET with channel_type=app and app_key', () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'welcome': '您好',
            'close': '再见',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = ApiClient(_config(), httpClient: mock);
      final json = await api.publicConfig(locale: 'zh-CN');

      expect(seen.method, 'GET');
      expect(seen.url.path, '/api/livechat/v1/public-config');
      expect(seen.url.queryParameters['channel_type'], 'app');
      expect(seen.url.queryParameters['app_key'], 'app_xxx');
      expect(seen.url.queryParameters['locale'], 'zh-CN');
      expect(json['welcome'], '您好');
    });
  });

  group('ApiClient.init', () {
    test('does not send Authorization on first app init', () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'visitor_id': 'v_1',
            'contact_id': 12345,
            'token': 'visitor_token_value',
            'token_exp': 1778755200,
            'realtime': {'url': 'wss://chat.example.com/connection/websocket'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = ApiClient(_config(), httpClient: mock);
      final json = await api.init(
        identity: const VisitorIdentity(
          customerId: 'cust_1',
          name: 'Alice',
          identityToken: 'identity.jwt',
        ),
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/livechat/v1/init');
      expect(seen.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['channel_type'], 'app');
      expect(body['app_key'], 'app_xxx');
      expect(body['customer_id'], 'cust_1');
      expect(body['identity_token'], 'identity.jwt');
      expect((body['user'] as Map)['name'], 'Alice');
      expect(json['visitor_id'], 'v_1');
    });

    test('sends old visitor token as Authorization on renewal', () async {
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'visitor_id': 'v_1',
            'contact_id': 12345,
            'token': 'new_visitor_token',
            'token_exp': 1778755200,
            'realtime': {'url': 'wss://x'},
          }),
          200,
        );
      });

      final api = ApiClient(_config(), httpClient: mock);
      await api.init(
        identity: const VisitorIdentity(),
        oldVisitorToken: 'expired_but_within_window',
      );

      expect(seen.headers['Authorization'], 'Bearer expired_but_within_window');
    });
  });

  group('ApiClient.sendText', () {
    test('sends visitor token and unwraps the message envelope', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'conversation': {
              'uuid': 'conv_1',
              'status': 'assigned',
              'channel_type': 'app',
              'channel_id': 'app_xxx',
            },
            'message': {
              'uuid': 'msg_1',
              'conversation_id': 'conv_1',
              'client_msg_id': 'c_abc',
              'sender_type': 'visitor',
              'sender_id': 'v_1',
              'content_type': 'text',
              'content': {'text': 'hello'},
              'created_at': 1778668800,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = ApiClient(_config(), httpClient: mock);
      final result = await api.sendText(
        visitorToken: 'visitor_token_value',
        conversationId: 'conv_1',
        text: 'hello',
        clientMsgId: 'c_abc',
      );
      final msg = result.message;
      expect(msg.uuid, 'msg_1');
      expect(msg.contentType, 'text');
      expect(msg.content['text'], 'hello');
    });
  });

  group('ApiClient error mapping', () {
    test('throws tokenExpired for 401 LC_TOKEN_EXPIRED', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'error_code': 'LC_TOKEN_EXPIRED', 'msg': 'expired'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(_config(), httpClient: mock);
      try {
        await api.publicConfig();
        fail('expected exception');
      } on HermesLiveChatException catch (e) {
        expect(e.error, HermesLiveChatError.tokenExpired);
        expect(e.code, 'LC_TOKEN_EXPIRED');
        expect(e.status, 401);
      }
    });

    test('throws orgDisabled for 403 LC_ORG_LIVECHAT_DISABLED', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'error_code': 'LC_ORG_LIVECHAT_DISABLED'}),
          403,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(_config(), httpClient: mock);
      try {
        await api.publicConfig();
        fail('expected exception');
      } on HermesLiveChatException catch (e) {
        expect(e.error, HermesLiveChatError.orgDisabled);
      }
    });
  });
}
