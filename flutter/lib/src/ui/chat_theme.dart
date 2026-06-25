import 'package:flutter/material.dart';

/// Hermes 客服气泡的固定调色板。
///
/// SDK 自身不定义主题，原先所有颜色都取自宿主 App 的 `Theme.of(context).colorScheme`，
/// 导致在不同宿主下观感不一致。这里把 widget（网页客服）的卡片化蓝色风格固化为常量，
/// 由 [hermesChatTheme] 注入一层固定 `Theme`，使 SDK 在任意宿主下都呈现统一风格。
///
/// 取值与 widget `frame.css` 同源，禁止在 UI 代码里散落裸 `Color(0x...)`。
abstract final class HermesChatPalette {
  /// 主色：访客气泡底、发送按钮、已连接状态点、链接色。
  static const Color primary = Color(0xFF2563EB);

  /// 主色之上的前景色（白）。
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// 屏幕背景：消息列表区底色。
  static const Color screenBackground = Color(0xFFF5F7FB);

  /// 面色：AppBar / 输入区 / 卡片表面（白）。
  static const Color surface = Color(0xFFFFFFFF);

  /// bot 气泡描边色。
  static const Color botBubbleBorder = Color(0xFFE2E8F0);

  /// 弱面色：输入框填充、图片占位底、行内 code 底色。
  static const Color surfaceMuted = Color(0xFFF1F5F9);

  /// 主文本色（bot 气泡正文、标题）。
  static const Color textPrimary = Color(0xFF111827);

  /// 次文本 / 弱文本色：时间戳、状态文案、空态提示。
  static const Color textMuted = Color(0xFF64748B);

  /// 连接中状态点（琥珀）。
  static const Color statusConnecting = Color(0xFFF59E0B);

  /// 错误色：断开状态点、错误文字。
  static const Color error = Color(0xFFB91C1C);

  /// 错误条背景。
  static const Color errorContainer = Color(0xFFFEF2F2);

  /// bot 气泡圆角半径（与 widget `.bubble` 一致）。
  static const double bubbleRadius = 16;

  /// 气泡尾角小圆角（贴近发送方一侧）。
  static const double bubbleTailRadius = 4;
}

/// 构造 Hermes 客服页使用的固定 [ThemeData]。
///
/// 仅覆盖 [ColorScheme] 中本页实际用到的角色，使每个 `colorScheme.xxx` 取色都落到
/// [HermesChatPalette] 上；同时设置 `scaffoldBackgroundColor` 为屏幕背景色。
ThemeData hermesChatTheme() {
  // 以默认 light 配色为基底，仅 copyWith 覆盖本页用到的角色，避免手填全部字段。
  final ColorScheme scheme = const ColorScheme.light().copyWith(
    primary: HermesChatPalette.primary,
    onPrimary: HermesChatPalette.onPrimary,
    surface: HermesChatPalette.surface,
    onSurface: HermesChatPalette.textPrimary,
    surfaceContainerHighest: HermesChatPalette.surfaceMuted,
    onSurfaceVariant: HermesChatPalette.textMuted,
    tertiary: HermesChatPalette.statusConnecting,
    error: HermesChatPalette.error,
    onError: HermesChatPalette.onPrimary,
    errorContainer: HermesChatPalette.errorContainer,
    onErrorContainer: HermesChatPalette.error,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: HermesChatPalette.screenBackground,
  );
}
