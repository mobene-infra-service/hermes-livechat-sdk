import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_livechat/src/internal/message_content.dart';

/// [MessageContentType] / [MessageSenderType] / [MessageDisplayRules] 的纯函数单测。
///
/// 这些规则不依赖 Flutter UI（无 BuildContext / 无网络），覆盖
/// 「类型映射」「展示文案兜底」「是否渲染 markdown」「排序权重」四类核心业务规则，
/// 与 Android 端 MessageContentTest 一一对应。
void main() {
  group('MessageContentType.fromRaw', () {
    test('已知字符串映射到对应枚举', () {
      expect(MessageContentType.fromRaw('text'), MessageContentType.text);
      expect(MessageContentType.fromRaw('image'), MessageContentType.image);
      expect(MessageContentType.fromRaw('file'), MessageContentType.file);
      expect(MessageContentType.fromRaw('welcome'), MessageContentType.welcome);
      expect(MessageContentType.fromRaw('close'), MessageContentType.close);
    });

    test('未知或 null 回退到 unknown', () {
      expect(MessageContentType.fromRaw('brand_new'), MessageContentType.unknown);
      expect(MessageContentType.fromRaw(null), MessageContentType.unknown);
      expect(MessageContentType.fromRaw(''), MessageContentType.unknown);
    });
  });

  group('MessageSenderType.isMine', () {
    test('仅访客判定为本人', () {
      expect(MessageSenderType.fromRaw('visitor').isMine, isTrue);
      expect(MessageSenderType.fromRaw('agent').isMine, isFalse);
      expect(MessageSenderType.fromRaw('bot').isMine, isFalse);
      expect(MessageSenderType.fromRaw('system').isMine, isFalse);
      // 未知发送方按「非本人」兜底，保证对方消息仍走 markdown 渲染。
      expect(MessageSenderType.fromRaw('anything').isMine, isFalse);
      expect(MessageSenderType.fromRaw(null).isMine, isFalse);
    });
  });

  group('MessageDisplayRules.displayText', () {
    test('text/welcome/close 取 text，缺省空串', () {
      expect(
        MessageDisplayRules.displayText(rawContentType: 'text', text: '你好'),
        '你好',
      );
      expect(
        MessageDisplayRules.displayText(rawContentType: 'welcome', text: '欢迎'),
        '欢迎',
      );
      expect(
        MessageDisplayRules.displayText(rawContentType: 'close'),
        '',
      );
    });

    test('image 取 caption，缺省空串', () {
      expect(
        MessageDisplayRules.displayText(
          rawContentType: 'image',
          caption: '配图说明',
          text: '不应使用 text',
        ),
        '配图说明',
      );
      expect(
        MessageDisplayRules.displayText(rawContentType: 'image'),
        '',
      );
    });

    test('file/未知类型 取 text，缺省回退原始类型占位', () {
      expect(
        MessageDisplayRules.displayText(rawContentType: 'file'),
        '[file]',
      );
      expect(
        MessageDisplayRules.displayText(rawContentType: 'mystery'),
        '[mystery]',
      );
      expect(
        MessageDisplayRules.displayText(rawContentType: 'file', text: '附件.pdf'),
        '附件.pdf',
      );
    });
  });

  group('MessageDisplayRules.shouldRenderMarkdown', () {
    test('仅非本人消息渲染 markdown', () {
      expect(
        MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.visitor),
        isFalse,
      );
      expect(
        MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.bot),
        isTrue,
      );
      expect(
        MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.agent),
        isTrue,
      );
      expect(
        MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.system),
        isTrue,
      );
    });
  });

  group('MessageDisplayRules.sortRank', () {
    test('欢迎语0、关闭2、其余1', () {
      expect(MessageDisplayRules.sortRank('welcome'), 0);
      expect(MessageDisplayRules.sortRank('close'), 2);
      expect(MessageDisplayRules.sortRank('text'), 1);
      expect(MessageDisplayRules.sortRank('image'), 1);
      expect(MessageDisplayRules.sortRank('unknown_x'), 1);
    });
  });
}
