# Hermes LiveChat iOS SDK

用于在原生 iOS App 内接入在线客服。SDK 提供默认聊天页，也提供 headless API 供业务自定义 UI。

## 支持范围

- iOS 13+
- Swift 5.9+
- 完整 Xcode 环境

SDK 在 iOS 13+ 内处理默认 UIKit 页面、WebSocket 生命周期和 session 存储的系统差异。宿主 App 的 deployment target 不能低于 iOS 13；自定义 UI、登录态、identity token、后台/前台策略由接入方处理。

## 接入前准备

后端或运营需要提供：

| 参数 | 说明 |
|---|---|
| `baseUrl` | LiveChat 访客 API 地址，例如 `https://chat.example.com`。如果经过网关，可传 `https://host/api`，SDK 会继续拼 `/api/livechat/v1/...` |
| `appKey` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | 可选。默认从 `baseUrl` 推导到 `/connection/websocket` |
| `customerId` | 可选。业务侧稳定、不可枚举的用户标识，用于复用联系人和历史 |

后台还必须为该 `appKey` 配置启用的接待方案：

- `channel_type = app`
- `channel_ref = appKey`
- `receive_mode = bot_only`
- `bot_code` 指向可用 LiveChat 接待机器人

如果渠道存在但没有接待方案，SDK 会收到“接待方案不存在”。

## 安装

当前 SDK 以 Swift Package 形式维护在 `sdk/ios`。

在宿主 App 的 `Package.swift` 中添加：

```swift
.package(path: "../hermes-arke/sdk/ios")
```

然后在 target dependencies 中加入：

```swift
.product(name: "HermesLiveChat", package: "HermesLiveChat")
```

Xcode 工程也可以通过 `File > Add Package Dependencies...` 添加本地 package 路径。

生产环境建议使用 `https://` 和 `wss://`。测试环境如果使用 `http://`，需要在 `Info.plist` 放行 ATS；生产环境应使用可信证书。

## 默认聊天页

建议在 App 启动或业务模块初始化时调用一次：

```swift
import HermesLiveChat

HermesLiveChat.shared.configure(
    HermesLiveChatConfig(
        baseUrl: URL(string: "https://chat.example.com")!,
        appKey: "019e6335c04478838ef4f9418263d279"
        // realtimeUrl: URL(string: "wss://realtime.example.com/connection/websocket")!
    )
)
```

打开默认聊天页：

```swift
HermesLiveChatLauncher.present(
    from: self,
    identity: VisitorIdentity(
        customerId: currentUser.stableLivechatId,
        email: currentUser.email,
        name: currentUser.name,
        locale: "zh-CN"
    ),
    title: "在线客服",
    locale: "zh-CN",
    startSessionOnOpen: true
)
```

`startSessionOnOpen = true` 适合完整聊天页：进入页面会创建或续签 visitor session、恢复已有会话历史并连接实时通道。默认值 `false` 只适合“预览欢迎语、不创建 visitor”的入口。

默认聊天页已包含：

- 欢迎语和历史恢复
- 文本发送
- 实时消息和会话关闭事件
- 错误提示
- 关闭聊天页后不立即断开 WebSocket，默认 5 分钟 idle 后断开

默认 UI 不带图片选择器。如需图片、附件或完全自定义 UI，使用下面的 headless API。

## Headless API

拉欢迎语，不创建 visitor、不连接 WebSocket：

```swift
let welcome = try await HermesLiveChat.shared.prefetchWelcome(locale: "zh-CN")
```

创建或续签 visitor session，并连接 realtime；不会因为打开页面而创建空对话：

```swift
try await HermesLiveChat.shared.startSession(
    VisitorIdentity(
        customerId: currentUser.stableLivechatId,
        email: currentUser.email,
        name: currentUser.name,
        locale: "zh-CN",
        attrs: [
            "app_version": appVersion,
        ]
    )
)
```

监听事件：

```swift
let eventsTask = Task {
    for await event in HermesLiveChat.shared.events() {
        await MainActor.run {
            switch event {
            case .connectionStateChanged(let state):
                renderState(state)
            case .messageReceived(let message, _):
                appendMessage(message)
            case .conversationUpdated(let conversation):
                updateConversation(conversation)
            case .messageRead(_, let messageId, _):
                markRead(messageId)
            case .error(let error):
                showError(error)
            }
        }
    }
}
```

聊天页销毁时取消订阅：

```swift
eventsTask.cancel()
```

发送文本和图片：

```swift
let textMessage = try await HermesLiveChat.shared.sendText("你好，我想咨询订单问题")

let imageMessage = try await HermesLiveChat.shared.sendImage(
    data: imageData,
    mimeType: "image/jpeg",
    filename: "order.jpg"
)
```

首次发送会由服务端创建真实对话，并在同一个响应里返回 `welcome` 和本次用户消息。自定义 UI 若要一次性合并渲染，使用 `sendTextMessages()` / `sendImageMessages()`；`sendText()` / `sendImage()` 仍保持返回本次用户消息。SDK 也会把额外的 `welcome` 通过 `events()` 下发，并用响应消息去重后续 realtime。

拉历史和标记已读：

```swift
if let conversationId = HermesLiveChat.shared.currentConversationId {
    let messages = try await HermesLiveChat.shared.history(
        conversationId: conversationId,
        limit: 50
    )
    if let last = messages.last {
        try await HermesLiveChat.shared.markRead(
            conversationId: conversationId,
            messageId: last.uuid
        )
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
| `identityToken` | `is_auth=1` 时必填，由客户 App Backend 用 App Secret 签发 |

默认 `is_auth=0` 时，SDK 不需要客户 App Backend 签 token，也不需要 App secret。App Secret 不能放进 iOS App。

如果启用 `is_auth=1`，客户 App Backend 必须签发短期 HS256 `identity_token`，iOS App 再通过 `VisitorIdentity(identityToken: ...)` 传给 SDK。

## 生命周期

- visitor session 按 `appKey` 存在 iOS Keychain。
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
| 测试环境 HTTP 请求失败 | 未配置 ATS |

能力层 API 会抛出 `HermesLiveChatException`，业务侧按 `error.error` 映射提示即可。

## 本地验证

```bash
xcodebuild \
  -project sdk/ios/hermes-livechat/hermes-livechat.xcodeproj \
  -scheme HermesLiveChat \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Xcode 也可以直接打开 `sdk/ios/hermes-livechat/hermes-livechat.xcodeproj`，选择 sample App scheme 后运行。
