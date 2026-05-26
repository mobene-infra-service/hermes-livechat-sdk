import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/src/internal/util.dart';

void main() {
  group('DedupCache', () {
    test('returns true for first key, false for duplicates', () {
      final cache = DedupCache();
      expect(cache.add('a'), isTrue);
      expect(cache.add('a'), isFalse);
      expect(cache.add('b'), isTrue);
      expect(cache.add('b'), isFalse);
    });

    test('treats null and empty as new every time', () {
      final cache = DedupCache();
      expect(cache.add(null), isTrue);
      expect(cache.add(null), isTrue);
      expect(cache.add(''), isTrue);
      expect(cache.add(''), isTrue);
    });

    test('evicts oldest entries when capacity exceeded', () {
      final cache = DedupCache(capacity: 3);
      cache.add('a');
      cache.add('b');
      cache.add('c');
      cache.add('d'); // evicts 'a'
      expect(cache.add('a'), isTrue, reason: 'a was evicted');
      // Re-adding 'a' brings the cache over capacity again, so FIFO evicts 'b'.
      expect(cache.add('b'), isTrue, reason: 'b was evicted by re-adding a');
      expect(cache.add('c'), isTrue, reason: 'c was evicted by re-adding b');
      expect(cache.add('d'), isTrue, reason: 'd was evicted by re-adding c');
    });
  });

  group('Logger.redact', () {
    test('redacts Bearer header value', () {
      final result = Logger.redact(
        'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc',
      );
      expect(result, equals('Bearer ***'));
    });

    test('redacts standalone JWT-looking strings', () {
      final result = Logger.redact(
        'token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xyz abc',
      );
      expect(result, contains('***'));
      expect(result, isNot(contains('eyJ')));
    });

    test('passes through plain strings unchanged', () {
      expect(Logger.redact('hello'), equals('hello'));
    });

    test('handles null / empty', () {
      expect(Logger.redact(null), equals(''));
      expect(Logger.redact(''), equals(''));
    });
  });

  group('newClientMsgId', () {
    test('produces unique values with c_ prefix', () {
      final a = newClientMsgId();
      final b = newClientMsgId();
      expect(a, startsWith('c_'));
      expect(b, startsWith('c_'));
      expect(a, isNot(equals(b)));
    });
  });
}
