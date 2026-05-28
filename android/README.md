# Hermes LiveChat Android SDK

用于在原生 Android App 内接入在线客服。SDK 提供默认聊天页，也提供 headless API 供业务自定义 UI。

## 支持范围

- Android API 23+
- Android Gradle Plugin `8.7.3`
- Kotlin Android plugin `2.0.21`
- Java 17
- `compileSdk` 35

SDK 在 Android API 23+ 内处理默认 UI、WebSocket 生命周期和 session 存储的系统差异。宿主 App 的 `minSdk` 不能低于 23；自定义 UI、登录态、identity token、后台/前台策略由接入方处理。

## 接入前准备

后端或运营需要提供：

| 参数 | 说明 |
|---|---|
| `baseUrl` | LiveChat 访客 API 地址，例如 `https://chat.example.com`。如果经过网关，可传 `https://host/api`，SDK 会继续拼 `/api/livechat/v1/...` |
| `appKey` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | 可选。默认从 `baseUrl` 推导到 `/connection/websocket` |
| `customerId` | 可选。业务侧稳定、不可枚举的用户标识，用于复用联系人和历史 |

后台编辑 App 渠道时，开关名称是「Secret 验证」。App Secret 只在管理后台和客户 App Backend 使用，不是 Android SDK 参数：

| 配置项 | 配置位置 | 说明 |
|---|---|---|
| `Secret 验证` (`is_auth`) | LiveChat 管理后台 App 渠道 | 关闭表示弱绑定模式；开启表示强身份签名校验 |
| `Secret Key` / `App Secret` | LiveChat 管理后台 App 渠道 | 创建或编辑 App 渠道时生成/配置，客户 App Backend 保存，不能写进 Android App |
| `identity_token` | 客户 App Backend 签发 | 使用 App Secret 以 HS256 签发，Android App 通过 `VisitorIdentity(identityToken = ...)` 传给 SDK |

后台还必须为该 `appKey` 配置启用的接待方案：

- `channel_type = app`
- `channel_ref = appKey`
- `receive_mode = bot_only`
- `bot_code` 指向可用 LiveChat 接待机器人

如果渠道存在但没有接待方案，SDK 会收到“接待方案不存在”。

## 安装

当前 SDK 以本地 Gradle module 维护在 `sdk/android/hermes-livechat`：

```kotlin
dependencies {
    implementation(project(":hermes-livechat"))
}
```

宿主 App 需要网络权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

测试环境如果使用 `http://`，需要允许明文流量：

```xml
<application android:usesCleartextTraffic="true" />
```

生产环境建议使用 `https://` 和 `wss://`。

## 默认聊天页

建议在 `Application.onCreate()` 或业务模块初始化时调用一次：

```kotlin
HermesLiveChat.configure(
    context = applicationContext,
    config = HermesLiveChatConfig(
        baseUrl = "https://chat.example.com",
        appKey = "019e6335c04478838ef4f9418263d279",
        // realtimeUrl = "wss://realtime.example.com/connection/websocket",
    ),
)
```

打开默认聊天页：

```kotlin
HermesLiveChatActivity.open(
    context = this,
    identity = VisitorIdentity(
        customerId = currentUser.stableLivechatId,
        name = currentUser.name,
        email = currentUser.email,
        locale = "zh-CN",
    ),
    title = "在线客服",
    locale = "zh-CN",
    startSessionOnOpen = true,
)
```

`startSessionOnOpen = true` 适合完整聊天页：进入页面会创建或续签 visitor session、恢复已有会话历史并连接实时通道。默认值 `false` 只适合“预览欢迎语、不创建 visitor”的入口。

默认聊天页已包含：

- 欢迎语和历史恢复
- 文本发送
- 实时消息和会话关闭事件
- 连接状态和错误提示
- 关闭聊天页后不立即断开 WebSocket，默认 5 分钟 idle 后断开

默认 UI 不带图片选择器。如需图片、附件或完全自定义 UI，使用下面的 headless API。

## Headless API

拉欢迎语，不创建 visitor、不连接 WebSocket：

```kotlin
val welcome = HermesLiveChat.prefetchWelcome(locale = "zh-CN")
```

创建或续签 visitor session，并连接 realtime；不会因为打开页面而创建空对话：

```kotlin
HermesLiveChat.startSession(
    VisitorIdentity(
        customerId = currentUser.stableLivechatId,
        name = currentUser.name,
        email = currentUser.email,
        locale = "zh-CN",
        attrs = mapOf("app_version" to appVersion),
    ),
)
```

监听事件：

```kotlin
val job = lifecycleScope.launch {
    HermesLiveChat.events.collect { event ->
        when (event) {
            is HermesLiveChatEvent.ConnectionStateChanged -> renderState(event.state)
            is HermesLiveChatEvent.MessageReceived -> appendMessage(event.message)
            is HermesLiveChatEvent.ConversationUpdated -> updateConversation(event.conversation)
            is HermesLiveChatEvent.MessageRead -> markRead(event.messageId)
            is HermesLiveChatEvent.Error -> showError(event.error)
        }
    }
}
```

聊天页销毁时取消订阅：

```kotlin
job.cancel()
```

发送文本和图片：

```kotlin
val textMessage = HermesLiveChat.sendText("你好，我想咨询订单问题")

val imageMessage = HermesLiveChat.sendImage(
    bytes = imageBytes,
    mimeType = "image/jpeg",
    filename = "order.jpg",
)
```

首次发送会由服务端创建真实对话，并在同一个响应里返回 `welcome` 和本次用户消息。自定义 UI 若要一次性合并渲染，使用 `sendTextMessages()` / `sendImageMessages()`；`sendText()` / `sendImage()` 仍保持返回本次用户消息。SDK 也会把额外的 `welcome` 通过 `events` 下发，并用响应消息去重后续 realtime。

拉历史和标记已读：

```kotlin
val conversationId = HermesLiveChat.currentConversationId
if (conversationId != null) {
    val messages = HermesLiveChat.history(conversationId = conversationId, limit = 50)
    messages.lastOrNull()?.let {
        HermesLiveChat.markRead(conversationId = conversationId, messageId = it.uuid)
    }
}
```

## 身份字段

| 字段 | 建议 |
|---|---|
| `customerId` | 首选。用于把业务用户和 LiveChat contact 绑定 |
| `externalUserId` | 兼容旧字段；新接入优先用 `customerId` |
| `name` / `email` / `avatar` | 展示和客服识别，不作为强认证凭据 |
| `businessId` / `ticketId` | 可选业务上下文 |
| `attrs` | 扩展上下文，例如会员等级、订单号、App 版本 |
| `identityToken` | 「Secret 验证」开启时必填，由客户 App Backend 用 App Secret 签发 |

默认「Secret 验证」关闭时，SDK 不需要客户 App Backend 签 token，也不需要 App secret。App Secret 不能放进 Android App。

如果启用「Secret 验证」，客户 App Backend 必须签发短期 HS256 `identity_token`，Android App 再通过 `VisitorIdentity(identityToken = ...)` 传给 SDK。

## 生命周期

- visitor session 按 `appKey` 用 Android Keystore 加密后持久化。
- `currentConversationId` 会在发消息、拉历史、收到实时事件时更新。
- token 临近过期时，发送消息、拉历史、已读等操作会自动重走 `/init` 续签。
- 默认 UI 关闭时不立即断开 WebSocket；SDK 默认 5 分钟 idle 后断开。
- `disconnect()` 只断开 realtime，不清空本地 session。
- `destroy()` 会断开 realtime，并清空 SDK 内存状态。切租户、切账号或退出登录时使用。

## 常见问题

| 表现 | 常见原因 |
|---|---|
| 渠道不存在 | `appKey` 写错或环境不一致 |
| 接待方案不存在 | App 渠道未绑定启用的接待方案 |
| `channelDisabled` | App 渠道被禁用 |
| `orgDisabled` | 机构未开通 LiveChat |
| 收不到实时消息 | WebSocket 地址不可达、Centrifugo 未配置、设备网络拦截 |
| 测试环境 HTTP 请求失败 | 未配置 `usesCleartextTraffic` 或 Network Security Config |

能力层 API 会抛出 `HermesLiveChatException`，业务侧按 `error.error` 映射提示即可。

## 本地构建

```bash
cd sdk/android
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools \
./gradlew :hermes-livechat:assembleDebug
```

如果本机已配置 `sdk.dir` 或 `ANDROID_HOME`，可以直接运行：

```bash
./gradlew :hermes-livechat:assembleDebug
```
