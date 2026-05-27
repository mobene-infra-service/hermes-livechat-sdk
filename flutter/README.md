# Hermes LiveChat Flutter SDK 接入

Hermes LiveChat Flutter SDK 用于客户 App 内接入在线咨询。提供基础聊天 UI，也保留能力层 API 供业务 App 自定义聊天页。

接入方式：App 用公开 `app_key` 初始化；业务用户 ID 作为弱绑定字段传给 LiveChat，用来复用联系人和历史会话，不作为强认证凭据。

## 接入前准备

需要后端或运营先提供：

| 参数 | 示例 | 说明 |
|---|---|---|
| `baseUrl` | `https://chat.example.com` | LiveChat 访客 REST API 公网地址 |
| `appKey` | `019e6335c04478838ef4f9418263d279` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | `wss://chat.example.com/connection/websocket` | 可选；不传时 SDK 从 `baseUrl` 自动推导 |
| `customerId` | `u_8f3a...` | 可选；业务侧稳定、不可枚举的用户标识 |

SDK 不需要客户 App Backend 签 token，不需要 App secret，也不需要 `X-Arke-Service-Token`。

## 安装

使用 path 方式接入：

```yaml
dependencies:
  hermes_livechat:
    path: ../hermes-arke/sdk/flutter
```

要求：

- Dart `>=3.0.0 <4.0.0`
- Flutter `>=3.10.0`

## 三端 SDK 说明

当前 `sdk/flutter/` 是 Flutter package，适用于 Flutter App。纯 Android 或纯 iOS App 不能直接 import 这个包，需要独立 native SDK。

SDK 能力按三端对齐：

| SDK | 语言 / 包形态 | UI |
|---|---|---|
| Flutter SDK | Dart package，`sdk/flutter/` | 基础聊天页 + 能力层 API |
| Android SDK | Kotlin 优先，Java 兼容；`sdk/android/` | 基础聊天页 + 能力层 API |
| iOS SDK | Swift Package；`sdk/ios/` | 基础聊天页 + 能力层 API |

三端 API 语义保持一致：

- `configure(baseUrl, appKey, realtimeUrl?)`
- `prefetchWelcome(locale?)`
- `startSession(identity)`
- `sendText(text, conversationId?)`
- `sendImage(...)`
- `history(conversationId, afterId?, limit?)`
- `markRead(conversationId, messageId)`
- `events`
- 默认聊天页和入口按钮
- `startSessionOnOpen` 默认 `false`

协议是跨平台的，核心流程不变：用 `baseUrl + appKey` 初始化；打开入口先拉 `/public-config`；首次发送前 `/init` 换 visitor token；后续 REST 和 Centrifugo realtime 使用同一个 visitor token。

Android / iOS 实时通道使用 Centrifugo 官方维护的 native client：`centrifuge-java` 用于 Android / Java，`centrifuge-swift` 用于 iOS。

## 快速接入基础 UI

### 1. App 启动时配置

```dart
import 'package:flutter/foundation.dart';
import 'package:hermes_livechat/hermes_livechat.dart';

void initLiveChat() {
  HermesLiveChat.instance.configure(
    HermesLiveChatConfig(
      baseUrl: 'https://chat.example.com',
      appKey: '019e6335c04478838ef4f9418263d279',
      logger: debugPrint,
    ),
  );
}
```

`configure()` 调一次即可。切换租户、切换账号或需要完全重置 SDK 时，先调用 `destroy()` 再重新 `configure()`。

### 2. 打开默认聊天页

入口按钮：

```dart
HermesLiveChatLauncher(
  identity: VisitorIdentity(
    customerId: currentUser.stableLivechatId,
    name: currentUser.name,
    email: currentUser.email,
    locale: 'zh-CN',
  ),
);
```

或从业务入口手动 push：

```dart
Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => HermesLiveChatPage(
      identity: VisitorIdentity(
        customerId: currentUser.stableLivechatId,
        name: currentUser.name,
        email: currentUser.email,
        locale: 'zh-CN',
      ),
      title: '在线客服',
      locale: 'zh-CN',
      // 默认 false：打开页面只拉欢迎语，首次发送前才创建 visitor。
      // 如果业务希望进入页面就恢复历史，可设为 true。
      startSessionOnOpen: false,
    ),
  ),
);
```

默认聊天页会处理：

- 拉欢迎语
- 首次发送前创建 visitor session
- 文本发送
- 历史消息
- 实时下行消息
- 连接状态和错误提示
- 会话关闭后的输入禁用

默认 UI 不带图片选择器；业务 App 可以继续用能力层的 `sendImage()` 接入自己的图片选择和预览。

`startSessionOnOpen` 默认是 `false`，以保持“打开入口只拉欢迎语，不创建 visitor”的流程。设为 `true` 时，进入聊天页会立即创建 / 续签 session 并尝试恢复当前会话历史。

## 自定义 UI 接入

如果业务 App 要完全自定义聊天页，直接使用下面的能力层 API。

### 1. 打开聊天入口时拉欢迎语

```dart
final welcome = await HermesLiveChat.instance.prefetchWelcome(locale: 'zh-CN');
```

这一步只读取配置，不创建 visitor，不连接 WebSocket。业务 UI 可以把 `welcome` 展示成第一条欢迎语。

### 2. 用户首次发送前创建会话

```dart
await HermesLiveChat.instance.startSession(
  VisitorIdentity(
    customerId: currentUser.stableLivechatId,
    name: currentUser.name,
    email: currentUser.email,
    locale: 'zh-CN',
    attrs: {
      'vip_level': currentUser.vipLevel,
      'app_version': appVersion,
    },
  ),
);
```

`startSession()` 会调用 `/init`，拿到 visitor token，并用同一个 token 连接 Centrifugo。后续 REST 和实时消息鉴权都由 SDK 内部处理。

### 3. 监听消息和状态

```dart
final subscription = HermesLiveChat.instance.events.listen((event) {
  if (event is ConnectionStateChanged) {
    renderConnectionState(event.state);
    return;
  }

  if (event is MessageReceived) {
    appendMessage(event.message);
    return;
  }

  if (event is ConversationUpdated) {
    updateConversation(event.conversation);
    return;
  }

  if (event is MessageRead) {
    markMessageRead(event.messageId, event.readAt);
  }
});
```

聊天页销毁时记得取消业务侧订阅：

```dart
await subscription.cancel();
```

### 4. 发送消息

```dart
try {
  final message = await HermesLiveChat.instance.sendText('你好，我想咨询订单问题');
  appendMessage(message);
} on HermesLiveChatException catch (error) {
  showLivechatError(error);
}
```

发送图片：

```dart
await HermesLiveChat.instance.sendImage(
  bytes: imageBytes,
  mimeType: 'image/jpeg',
);
```

拉历史和已读：

```dart
final conversationId = HermesLiveChat.instance.currentConversationId;
if (conversationId != null) {
  final messages = await HermesLiveChat.instance.history(
    conversationId: conversationId,
    limit: 50,
  );

  await HermesLiveChat.instance.markRead(
    conversationId: conversationId,
    messageId: messages.last.uuid,
  );
}
```

## 身份字段怎么传

| 字段 | 建议 |
|---|---|
| `customerId` | 首选，用于把业务用户和 LiveChat contact 绑定 |
| `externalUserId` | 兼容旧字段；没有历史包袱时优先用 `customerId` |
| `name` / `email` / `avatar` | 展示和客服识别用，不参与强认证 |
| `attrs` | 业务扩展信息，例如会员等级、App 版本、订单上下文 |

注意：

- `customerId` 是客户端声明字段，只能做弱绑定，不能当登录态认证结果。
- 不要传自增 ID、手机号、邮箱等可猜测或敏感值。
- 建议传稳定、不可枚举的业务用户 ID，或服务端生成的哈希 ID。
- 如需要身份防伪造，请接入服务端签名身份模式。

## 生命周期

- 进入后台后，SDK 默认等待 30 秒再断开 WebSocket，避免短暂切后台造成频繁重连。
- 回到前台时，SDK 会自动重连。
- visitor token 临近过期时，发送消息、拉历史、已读等操作会自动重走 `/init` 续签。
- 断线重连后，业务层可用 `history(afterId: lastMessageId)` 拉补缺失消息；SDK 会对 realtime 事件做短期去重。

## 常见问题

**`notConfigured`**

先调用 `HermesLiveChat.instance.configure(...)`。

**`channelDisabled` / `orgDisabled`**

检查管理后台 App 渠道是否启用、机构是否开通 LiveChat。

**收不到实时消息**

检查 `baseUrl` 推导出的 WebSocket 地址是否可访问；如生产地址不是同域，显式配置 `realtimeUrl`。

**同一个用户历史会话对不上**

检查 `customerId` 是否稳定且一人一值。不要给匿名用户统一传同一个兜底 ID。
