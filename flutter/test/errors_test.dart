import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/src/errors.dart';

void main() {
  group('HermesLiveChatException.fromBackend', () {
    test('maps LC_TOKEN_EXPIRED to tokenExpired', () {
      final exception = HermesLiveChatException.fromBackend(
        status: 401,
        code: 'LC_TOKEN_EXPIRED',
        message: 'token expired',
      );
      expect(exception.error, HermesLiveChatError.tokenExpired);
      expect(exception.status, 401);
      expect(exception.code, 'LC_TOKEN_EXPIRED');
    });

    test('maps LC_ORG_LIVECHAT_DISABLED to orgDisabled', () {
      final exception = HermesLiveChatException.fromBackend(
        status: 403,
        code: 'LC_ORG_LIVECHAT_DISABLED',
      );
      expect(exception.error, HermesLiveChatError.orgDisabled);
    });

    test(
      'maps LC_REALTIME_CONNECT_UNAUTHORIZED to realtimeConnectUnauthorized',
      () {
        final exception = HermesLiveChatException.fromBackend(
          status: 401,
          code: 'LC_REALTIME_CONNECT_UNAUTHORIZED',
        );
        expect(
          exception.error,
          HermesLiveChatError.realtimeConnectUnauthorized,
        );
      },
    );

    test('falls back to status-based mapping when code is unknown', () {
      expect(
        HermesLiveChatException.fromBackend(status: 400).error,
        HermesLiveChatError.badRequest,
      );
      expect(
        HermesLiveChatException.fromBackend(status: 401, code: 'WAT').error,
        HermesLiveChatError.tokenInvalid,
      );
      expect(
        HermesLiveChatException.fromBackend(status: 503).error,
        HermesLiveChatError.realtimeProviderUnavailable,
      );
    });

    test('falls back to unknown for 404 without code', () {
      expect(
        HermesLiveChatException.fromBackend(status: 404).error,
        HermesLiveChatError.unknown,
      );
    });
  });
}
