# Hermes LiveChat iOS SDK 接入

Hermes LiveChat iOS SDK 用于原生 iOS App 内接入在线客服。提供基础聊天页，也提供能力层 API 供业务 App 自定义 UI。

接入方式：App 用公开 `app_key` 初始化；业务用户 ID 作为弱绑定字段传给 LiveChat，用来复用联系人和历史会话，不作为强认证凭据。

阅读本文前，假定你已经具备基础 iOS / Swift 开发经验，能添加 Swift Package、修改 `Info.plist`，并能在 Simulator 或真机上运行调试 App。

## 目录

1. 接入前准备
2. 安装
3. 网络配置
4. 五步快速接入
5. 自定义 UI 接入
6. 常见使用场景
7. API 接口速查
8. 生命周期和 session
9. 错误处理
10. 本地验证

## 接入前准备

需要后端或运营先提供：

| 参数 | 示例 | 说明 |
|---|---|---|
| `baseUrl` | `https://chat.example.com` | LiveChat 访客 REST API 公网地址。可带网关子路径前缀（例如 `https://hermes-test.financifyx.com/api`），SDK 内部会拼 `/api/livechat/v1/...`，不要写到该层 |
| `appKey` | `app_xxx` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | `wss://chat.example.com/connection/websocket` | 可选；不传时 SDK 从 `baseUrl` 自动推导 |
| `customerId` | `u_8f3a...` | 可选；业务侧稳定、不可枚举的用户标识 |

SDK 不需要客户 App Backend 签 token，不需要 App secret，也不需要 `X-Arke-Service-Token`。`Secret Key` 不能放进 iOS App。

后台必须为这个 `appKey` 绑定并启用接待方案：

- `channel_type`: `app`
- `channel_ref`: 对应 `appKey`
- `receive_mode`: `bot_only`
- `bot_code`: 可用的 LiveChat 接待机器人

如果只创建 App 渠道但没有接待方案，`/public-config` 或 `/messages` 会返回“接待方案不存在”。

## 安装

当前 iOS SDK 以 Swift Package 形式维护在 `sdk/ios`。在宿主 App 的 `Package.swift` 中添加：

```swift
.package(path: "../hermes-arke/sdk/ios")
```

然后在 target dependencies 中加入：

```swift
.product(name: "HermesLiveChat", package: "HermesLiveChat")
```

Xcode 工程也可以通过 `File > Add Package Dependencies...` 添加本地 package 路径。

SDK 要求：

- iOS 13+
- Swift 5.9+
- 完整 Xcode 环境

SDK 依赖：

- `centrifuge-swift`
- `UIKit`

## 网络配置

生产环境建议使用 `https://` 和 `wss://`。如果测试环境使用 `http://`，宿主 App 需要在 `Info.plist` 中放行 ATS：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

只建议在测试 App 中这样配置。生产环境应使用可信证书。

## 五步快速接入

### 第一步：引入 SDK

通过 Swift Package Manager 添加本地 package：

```swift
.package(path: "../hermes-arke/sdk/ios")
```

### 第二步：配置网络

生产环境使用 HTTPS 时通常无需额外配置。测试环境如果是 HTTP，在 `Info.plist` 中放行 ATS。

### 第三步：初始化 SDK

建议在 App 启动或业务模块初始化时尽早调用：

```swift
import HermesLiveChat

func initLiveChat() {
    HermesLiveChat.shared.configure(
        HermesLiveChatConfig(
            baseUrl: URL(string: "https://chat.example.com")!,
            appKey: "app_xxx"
        )
    )
}
```

`configure()` 调一次即可。切换租户、切换账号或需要完全重置 SDK 时，先调用 `HermesLiveChat.shared.destroy()`，再重新 `configure()`。

`realtimeUrl` 可不传。默认推导规则：

- `https://chat.example.com` -> `wss://chat.example.com/connection/websocket`
- `http://chat.example.com` -> `ws://chat.example.com/connection/websocket`

如果生产 WebSocket 地址不是同域，显式传入：

```swift
HermesLiveChatConfig(
    baseUrl: URL(string: "https://chat.example.com")!,
    appKey: "app_xxx",
    realtimeUrl: URL(string: "wss://realtime.example.com/connection/websocket")!
)
```

### 第四步：打开默认聊天页

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
    startSessionOnOpen: false
)
```

### 第五步：Simulator 或真机验证

至少验证下面四件事：

- 打开聊天页能看到欢迎语。
- 发第一条消息前 SDK 能完成 `/init`。
- 文本消息能发送成功，并能收到实时回推。
- App 切后台 / 回前台后仍可继续发送消息。

默认聊天页会处理：

- 拉欢迎语
- 首次发送前创建 visitor session
- 文本发送
- 历史消息
- 实时下行消息
- 错误提示
- 会话关闭后的输入禁用

默认 UI 不带图片选择器；业务 App 可以继续用能力层的 `sendImage()` 接入自己的图片选择和预览。

`startSessionOnOpen` 默认是 `false`，以保持“打开入口只拉欢迎语，不创建 visitor”的流程。设为 `true` 时，进入聊天页会立即创建 / 续签 session 并尝试恢复当前会话历史。

## 自定义 UI 接入

如果业务 App 要完全自定义聊天页，直接使用能力层 API。

### 1. 打开聊天入口时拉欢迎语

```swift
let welcome = try await HermesLiveChat.shared.prefetchWelcome(locale: "zh-CN")
```

这一步只读取配置，不创建 visitor，不连接 WebSocket。业务 UI 可以把 `welcome` 展示成第一条欢迎语。

### 2. 用户首次发送前创建会话

```swift
try await HermesLiveChat.shared.startSession(
    VisitorIdentity(
        customerId: currentUser.stableLivechatId,
        email: currentUser.email,
        name: currentUser.name,
        locale: "zh-CN",
        attrs: [
            "vip_level": String(describing: currentUser.vipLevel),
            "app_version": appVersion,
        ]
    )
)
```

`startSession()` 会调用 `/init`，拿到 visitor token，并用同一个 token 连接 Centrifugo。后续 REST 和实时消息鉴权都由 SDK 内部处理。

### 3. 监听消息和状态

```swift
private var eventsTask: Task<Void, Never>?

eventsTask = Task {
    for await event in HermesLiveChat.shared.events() {
        await MainActor.run {
            switch event {
            case .connectionStateChanged(let state):
                renderConnectionState(state)
            case .messageReceived(let message, _):
                appendMessage(message)
            case .conversationUpdated(let conversation):
                updateConversation(conversation)
            case .messageRead(conversationId: let conversationId, messageId: let messageId, readAt: let readAt):
                markMessageRead(conversationId, messageId, readAt)
            case .error(let error):
                showLivechatError(error)
            }
        }
    }
}
```

聊天页销毁时取消业务侧订阅：

```swift
eventsTask?.cancel()
```

### 4. 发送消息

```swift
do {
    let message = try await HermesLiveChat.shared.sendText("你好，我想咨询订单问题")
    appendMessage(message)
} catch let error as HermesLiveChatException {
    showLivechatError(error)
}
```

发送图片：

```swift
try await HermesLiveChat.shared.sendImage(
    data: imageData,
    mimeType: "image/jpeg",
    filename: "order.jpg"
)
```

拉历史和已读：

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

## 常见使用场景

### 绑定业务用户

有登录态的 App 应传稳定的 `customerId`。同一个 `customerId` 会复用同一个 LiveChat contact 和历史会话：

```swift
VisitorIdentity(
    customerId: currentUser.stableLivechatId,
    email: currentUser.email,
    name: currentUser.name,
    locale: "zh-CN"
)
```

不要给所有匿名用户传同一个兜底 ID。匿名用户可以不传 `customerId`，由 LiveChat 生成 visitor。

### 上传业务上下文

可通过 `attrs` 传会员等级、订单号、App 版本等上下文，方便客服识别问题：

```swift
VisitorIdentity(
    customerId: currentUser.stableLivechatId,
    attrs: [
        "order_id": orderId,
        "vip_level": String(describing: currentUser.vipLevel),
        "app_version": appVersion,
    ]
)
```

### 测试环境使用 HTTP

如果 `baseUrl` 是 `http://...`，必须在 `Info.plist` 中放行 ATS。生产环境应改用 HTTPS 和可信证书。

### 只使用能力层，不使用默认 UI

业务 App 可以完全不调用 `HermesLiveChatLauncher.present()`，只使用 `prefetchWelcome()`、`startSession()`、`sendText()`、`events()` 等 API 自行渲染聊天页。

## 身份字段怎么传

| 字段 | 建议 |
|---|---|
| `customerId` | 首选，用于把业务用户和 LiveChat contact 绑定 |
| `externalUserId` | 兼容旧字段；没有历史包袱时优先用 `customerId` |
| `businessId` / `ticketId` | 可选；用于业务上下文绑定 |
| `number` | 可选；业务号码或外部渠道号码 |
| `name` / `email` / `avatar` | 展示和客服识别用，不参与强认证 |
| `attrs` | 业务扩展信息，例如会员等级、App 版本、订单上下文 |

注意：

- `customerId` 是客户端声明字段，只能做弱绑定，不能当登录态认证结果。
- 不要传自增 ID、手机号、邮箱等可猜测或敏感值。
- 建议传稳定、不可枚举的业务用户 ID，或服务端生成的哈希 ID。
- 如需要身份防伪造，请接入服务端签名身份模式。

## API 接口速查

| API | 作用 | 说明 |
|---|---|---|
| `HermesLiveChat.shared.configure(config)` | 初始化 SDK | 使用 `baseUrl`、`appKey`、可选 `realtimeUrl` |
| `prefetchWelcome(locale:)` | 拉欢迎语 | 不创建 visitor，不连接 WebSocket |
| `startSession(_:)` | 创建或续签会话 | 调 `/init`，拿 visitor token，连接 realtime |
| `sendText(_:conversationId:)` | 发送文本 | `conversationId` 可不传，默认使用当前会话 |
| `sendImage(data:mimeType:filename:conversationId:)` | 发送图片 | SDK 先 presign，再上传，再发消息 |
| `history(conversationId:afterId:limit:)` | 拉历史 | 可用于打开页面恢复历史或断线补拉 |
| `markRead(conversationId:messageId:)` | 标记已读 | 通常在收到非 visitor 消息后调用 |
| `events()` | 事件流 | 监听连接状态、消息、会话更新、已读、错误 |
| `disconnect()` | 断开 realtime | 不清空本地 session |
| `destroy()` | 清理 SDK 内存状态 | 切租户、切账号或退出时使用 |
| `HermesLiveChatLauncher.present(...)` | 打开默认聊天页 | 最低成本接入入口 |

## 生命周期和 session

- SDK 会把 visitor session 按 `appKey` 存在 iOS Keychain。
- `currentConversationId` 会在发消息、拉历史、收到实时事件时更新。
- visitor token 临近过期时，发送消息、拉历史、已读等操作会自动重走 `/init` 续签。
- `disconnect()` 只断开 realtime，不清空本地 session。
- `destroy()` 会断开 realtime，并清空 SDK 内存状态；重新使用前需要再次 `configure()`。
- iOS 宿主 App 如果需要后台断开 / 前台重连策略，可以在自己的 lifecycle 中调用 `disconnect()` 和 `startSession(identity)`。

## 错误处理

能力层 API 会抛出 `HermesLiveChatException`：

```swift
do {
    try await HermesLiveChat.shared.sendText("hello")
} catch let error as HermesLiveChatException {
    switch error.error {
    case .notConfigured:
        show("请先初始化客服")
    case .channelDisabled:
        show("客服渠道已禁用")
    case .orgDisabled:
        show("机构未开通在线客服")
    case .tokenExpired:
        show("会话已过期，请重试")
    case .network:
        show("网络异常，请稍后重试")
    default:
        show(error.message ?? "发送失败")
    }
}
```

常见后端配置问题：

| 表现 | 可能原因 |
|---|---|
| `渠道不存在` | `appKey` 不存在、写错，或环境不一致 |
| `接待方案不存在` | App 渠道未绑定启用的接待方案 |
| `channelDisabled` | App 渠道被禁用 |
| `orgDisabled` | 机构未开通 LiveChat |
| 收不到实时消息 | WebSocket 地址不可达、Centrifugo 未配置、设备网络拦截 |

## 本地验证

Package 解析：

```bash
swift package dump-package --package-path sdk/ios
```

UIKit / simulator 编译必须使用完整 Xcode 环境。可在宿主测试 App 中添加本 package，然后选择 iOS Simulator 或真机运行。

本目录已提供最小宿主测试 App：

```bash
cd sdk/ios/hermes-livechat
xcodebuild \
  -project hermes-livechat.xcodeproj \
  -scheme hermes-livechat \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Xcode 也可以直接打开 `sdk/ios/hermes-livechat/hermes-livechat.xcodeproj`，选择 `hermes-livechat` scheme 后运行。
