# LiveChat App SDK Draft（Flutter 实现）

> **Status**: draft — 2026-05-18
> **Owner**: cmd/livechat team
> **关联文档**：
> - 协议设计：[docs/design/livechat-design-p0.md](../../docs/design/livechat-design-p0.md)（§10.2 / §10.4 / §8.1）
> - 协议 RFC：[docs/design/livechat-protocol.md](../../docs/design/livechat-protocol.md)
> - 后端实现：`internal/livechat/{http.go, service.go, token.go}`
> - Web 参考实现：`widget/src/core/{api.ts, realtime.ts, storage.ts}`
> - Centrifuge Dart：<https://pub.dev/packages/centrifuge>（官方）

---

## 0. 一句话结论

下游客户 App 是 Flutter 时，App SDK 使用 Flutter / Dart package（`sdk/flutter/`），iOS + Android 可共享一套代码、一套 CI、一份维护成本。

---

## 1. Flutter 适用范围

- 客户消费端是 Flutter 时，直接 import `sdk/flutter/`；纯原生工程使用 `sdk/android/` 或 `sdk/ios/`。
- 协议层（REST + JWT + Centrifuge connect + 生命周期）跟 UI 完全无关，Dart 跑得动。
- Centrifugo 官方有 [centrifuge-dart](https://pub.dev/packages/centrifuge)，本地验签 JWT、自动 server-side subscribe、断线重连都内置。
- `WidgetsBindingObserver` 一个 callback 处理前后台，比 iOS `UIApplication.didEnterBackgroundNotification` + Android `ProcessLifecycleOwner` 加起来还少。
- `flutter_secure_storage` 同时映射到 iOS Keychain 和 Android Keystore。

---

## 2. 关键约束（来自设计 + 后端代码）

| # | 约束 | 来源 |
|---|---|---|
| 1 | P0 采用公开 `app_key` 初始化；App Backend 签名身份声明只作为强身份模式预留 | 设计 §10.4 |
| 2 | 两步握手：先 `GET /public-config` 拉欢迎语（不创建 visitor），首条消息前调 `POST /init` 拿 visitor token | 设计 §4.2 / §4.3 |
| 3 | 单 token：同一个 visitor token 同时用于 REST `Authorization: Bearer` 和 Centrifugo connection JWT | 设计 §4.1 |
| 4 | App `customer_id/external_user_id` 是客户端弱绑定 ID，用于 contact 复用；不能当强身份认证凭据 | 设计 §5 / §10.4 |
| 5 | Centrifugo 自动 server-side subscribe `lc.visitor.<visitor_id>`，SDK 不发 subscribe | 设计 §5.1 |
| 6 | 移动端进后台允许 disconnect；回前台 reconnect；token 过期重走 `/init` 静默续签 | 设计 §10.2 |
| 7 | P0 只支持 `content_type=text` 和 `content_type=image` | `internal/livechat/service.go` |
| 8 | publication 可丢；断线后 `GET /messages?after_id=` REST 拉补；幂等用 `client_msg_id` + 后端 `UNIQUE(conversation_id, client_msg_id)` | 设计 §6.7 / §7 |
| 9 | token 不能进日志 / URL / 崩溃上报 extra | 设计 §10.2 / §14 |

---

## 3. 目录结构

```
sdk/
├── PLAN.md                              # 本文档
├── README.md                            # 集成指引
├── pubspec.yaml                         # 包声明 + 依赖
├── analysis_options.yaml                # lint
├── .gitignore
└── lib/
    ├── hermes_livechat.dart             # public exports（barrel）
    └── src/
        ├── client.dart                  # HermesLiveChat facade（singleton）
        ├── config.dart                  # HermesLiveChatConfig
        ├── models.dart                  # Conversation / Message / Publication / ConversationEvent
        ├── public_types.dart            # VisitorIdentity / ConnectionState / Event sealed
        ├── errors.dart                  # HermesLiveChatError 枚举 + LC_* 映射
        ├── internal/
            ├── api_client.dart          # REST 客户端（package:http）
            ├── realtime.dart            # RealtimeTransport + CentrifugeRealtime
            ├── session.dart             # 会话状态 / token 续签 / dedup
            ├── storage.dart             # flutter_secure_storage 封装
            ├── lifecycle.dart           # WidgetsBindingObserver
            └── util.dart                # ClientMsgId / Logger（redact token）
        └── ui/
            └── chat_page.dart            # 基础聊天页 + 入口按钮
```

依赖（`pubspec.yaml`）：

- `centrifuge`：Centrifugo Dart client
- `http`：REST
- `flutter_secure_storage`：Keychain / Keystore
- `uuid`：client_msg_id
- `meta`：注解

---

## 4. 对外 API

```dart
// 进程级配置（启动时调一次）
HermesLiveChat.instance.configure(HermesLiveChatConfig(...));

// 拉欢迎语（打开聊天面板时；不创建 visitor）
final welcome = await HermesLiveChat.instance.prefetchWelcome(locale: 'zh-CN');

// 用户首条消息前；SDK 用 app_key 调 /init 拿 visitor token，建立 realtime
final session = await HermesLiveChat.instance.startSession(
  VisitorIdentity(customerId: 'cust_1', name: '张三'),
);

// 发文本 / 图片
final msg = await HermesLiveChat.instance.sendText('你好');
await HermesLiveChat.instance.sendImage(bytes, mimeType: 'image/jpeg');

// 已读 / 历史
await HermesLiveChat.instance.markRead(messageId: 'msg_xx', conversationId: 'conv_xx');
final messages = await HermesLiveChat.instance.history(
  conversationId: 'conv_xx',
  afterId: lastId,
);

// 主动断开 / 销毁
HermesLiveChat.instance.disconnect();
HermesLiveChat.instance.destroy();

// 基础 UI
HermesLiveChatLauncher(identity: VisitorIdentity(...));
HermesLiveChatPage(identity: VisitorIdentity(...));

// 事件订阅
HermesLiveChat.instance.events.listen((event) {
  switch (event) {
    case ConnectionStateChanged(state: final s):
    case MessageReceived(message: final m, conversation: final c):
    case ConversationUpdated(conversation: final c, event: final e):
    case MessageRead(messageId: final id, readAt: final at):
    case HermesError(error: final err):
  }
});
```

---

## 5. 关键设计点

1. **AppKey 初始化**：SDK 配置 `baseUrl + appKey` 即可；首次 `/init` 不依赖客户 App Backend。
2. **VisitorIdentity**：`customerId / externalUserId / businessId / number / ticketId / locale / attrs`，对应 `internal/livechat/service.go` 的 `contactAttrs`。
3. **RealtimeTransport 抽象**：`connect / disconnect / state stream / publication stream`；默认实现包装 `centrifuge`。换 transport 不影响 facade。
4. **AppLifecycle**：`WidgetsBindingObserver.didChangeAppLifecycleState`；`paused` 后延迟 30s disconnect；`resumed` 立即 reconnect；token 过期先 `/init` 续签。
5. **DedupCache**：FIFO 容量 256，键 = `event_id` ∪ `message.uuid` ∪ `client_msg_id`。
6. **Logger**：所有日志过 `redact(token)` 替换为 `***`；不打印 `Authorization` header 整串。
7. **错误映射**：`HermesLiveChatError` enum 对应设计 §16 错误码（`LC_TOKEN_EXPIRED` → `tokenExpired`，`LC_ORG_LIVECHAT_DISABLED` → `orgDisabled` 等）。

---

## 6. 验收

无 Flutter 工具链下，手动验证：

1. 协议契约逐项对照 `internal/livechat/http.go` + `service.go`：path / method / headers / body 字段名一致。
2. App `/init` body 字段与 `internal/livechat/types.go:initRequest` 一致；README 跑通公开 `app_key` 接入样例。
3. 错误码与 `docs/design/livechat-protocol.md` §10 / 设计 §16 对齐。
4. Centrifugo URL 和 visitor token 复用与设计 §4.1 + §4.8 一致。
5. 生命周期行为符合设计 §10.2（前后台、重连、续签）。
6. README 跑通「接入 5 步流程」：configure → prefetchWelcome → 用户点发送 → startSession → sendText。

`flutter pub get` / `flutter analyze` / `flutter test` 真实工具链验证由下游接入方负责，本草稿不绑死 `centrifuge` / `flutter_secure_storage` 等版本。

---

## 7. 不在草稿范围

- 深度 UI 主题定制 / 附件 picker
- 离线推送（FCM / APNs）—— 由 host App 负责
- 语音 / 视频消息
- 本地消息持久化（sqflite / Hive）
- Example App 工程
- `flutter pub get` 真实编译
- React Native 适配
