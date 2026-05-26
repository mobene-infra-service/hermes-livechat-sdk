# Hermes LiveChat Android SDK 接入

Hermes LiveChat Android SDK 用于原生 Android App 内接入在线客服。提供基础聊天页，也提供能力层 API 供业务 App 自定义 UI。

接入方式：App 用公开 `app_key` 初始化；业务用户 ID 作为弱绑定字段传给 LiveChat，用来复用联系人和历史会话，不作为强认证凭据。

阅读本文前，假定你已经具备基础 Android / Kotlin 开发经验，能修改 Gradle、Manifest，并能在真机或模拟器上安装调试 App。

## 目录

1. 接入前准备
2. 安装
3. 权限和网络
4. 五步快速接入
5. 自定义 UI 接入
6. 常见使用场景
7. API 接口速查
8. 生命周期和 session
9. 错误处理
10. 本地构建 SDK

## 接入前准备

需要后端或运营先提供：

| 参数 | 示例 | 说明 |
|---|---|---|
| `baseUrl` | `https://chat.example.com` | LiveChat 访客 REST API 公网地址 |
| `appKey` | `app_xxx` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | `wss://chat.example.com/connection/websocket` | 可选；不传时 SDK 从 `baseUrl` 自动推导 |
| `customerId` | `u_8f3a...` | 可选；业务侧稳定、不可枚举的用户标识 |

SDK 不需要客户 App Backend 签 token，不需要 App secret，也不需要 `X-Arke-Service-Token`。`Secret Key` 不能放进 Android App。

后台必须为这个 `appKey` 绑定并启用接待方案：

- `channel_type`: `app`
- `channel_ref`: 对应 `appKey`
- `receive_mode`: `bot_only`
- `bot_code`: 可用的 LiveChat 接待机器人

如果只创建 App 渠道但没有接待方案，`/public-config` 或 `/messages` 会返回“接待方案不存在”。

## 安装

当前 Android SDK 以 Gradle module 形式维护在 `sdk/android/hermes-livechat`。宿主 App 可以直接引入本地 module，也可以按业务发布流程打包成 Maven 依赖后接入。

本地 module 接入：

```kotlin
dependencies {
    implementation(project(":hermes-livechat"))
}
```

SDK 要求：

- Android Gradle Plugin `8.7.3`
- Kotlin Android plugin `2.0.21`
- Java 17
- `minSdk` 23
- `compileSdk` 35

SDK 依赖：

- `io.github.centrifugal:centrifuge-java`
- `okhttp`
- `kotlinx-coroutines-android`

## 权限和网络

宿主 App 必须有网络权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

如果测试环境使用 `http://`，宿主 App 需要允许明文流量：

```xml
<application
    android:usesCleartextTraffic="true">
</application>
```

生产环境建议使用 `https://` 和 `wss://`，并确认 Android 设备信任服务端证书。

## 五步快速接入

### 第一步：引入 SDK

在宿主 App 的 Gradle module 中依赖 `hermes-livechat`：

```kotlin
dependencies {
    implementation(project(":hermes-livechat"))
}
```

### 第二步：配置网络权限

在宿主 App 的 `AndroidManifest.xml` 中加入：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

测试环境如果是 HTTP，同时配置：

```xml
<application android:usesCleartextTraffic="true">
</application>
```

### 第三步：初始化 SDK

建议在 `Application.onCreate()` 或业务模块初始化时尽早调用：

```kotlin
import android.content.Context
import com.mobene.hermes.livechat.HermesLiveChat
import com.mobene.hermes.livechat.HermesLiveChatConfig

fun initLiveChat(context: Context) {
    HermesLiveChat.configure(
        context = context.applicationContext,
        config = HermesLiveChatConfig(
            baseUrl = "https://chat.example.com",
            appKey = "app_xxx",
        ),
    )
}
```

`configure()` 调一次即可。切换租户、切换账号或需要完全重置 SDK 时，先调用 `HermesLiveChat.destroy()`，再重新 `configure()`。

`realtimeUrl` 可不传。默认推导规则：

- `https://chat.example.com` -> `wss://chat.example.com/connection/websocket`
- `http://chat.example.com` -> `ws://chat.example.com/connection/websocket`

如果生产 WebSocket 地址不是同域，显式传入：

```kotlin
HermesLiveChatConfig(
    baseUrl = "https://chat.example.com",
    appKey = "app_xxx",
    realtimeUrl = "wss://realtime.example.com/connection/websocket",
)
```

### 第四步：打开默认聊天页

```kotlin
import com.mobene.hermes.livechat.VisitorIdentity
import com.mobene.hermes.livechat.ui.HermesLiveChatActivity

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

### 第五步：真机或模拟器验证

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
- 连接状态和错误提示
- 会话关闭后的输入禁用

默认 UI 不带图片选择器；业务 App 可以继续用能力层的 `sendImage()` 接入自己的图片选择和预览。

`startSessionOnOpen` 默认是 `false`，以保持“打开入口只拉欢迎语，不创建 visitor”的流程。正式接入聊天页时建议显式设为 `true`：进入页面会立即创建 / 续签 session，并根据 SDK 本地保存的 `lastConversationId` 恢复当前会话历史。否则用户退出聊天页后再打开，只会先看到欢迎语，容易被误认为是新会话。

如果业务入口只是“客服预览 / 欢迎语预取”，可以继续使用 `false`；如果入口就是完整聊天页，使用 `true`。

## 自定义 UI 接入

如果业务 App 要完全自定义聊天页，直接使用能力层 API。

下面的能力层方法都是 `suspend` 方法，需要在 `lifecycleScope`、`viewModelScope` 或业务自己的 coroutine scope 中调用。

### 1. 打开聊天入口时拉欢迎语

```kotlin
val welcome = HermesLiveChat.prefetchWelcome(locale = "zh-CN")
```

这一步只读取配置，不创建 visitor，不连接 WebSocket。业务 UI 可以把 `welcome` 展示成第一条欢迎语。

### 2. 用户首次发送前创建会话

```kotlin
HermesLiveChat.startSession(
    VisitorIdentity(
        customerId = currentUser.stableLivechatId,
        name = currentUser.name,
        email = currentUser.email,
        locale = "zh-CN",
        attrs = mapOf(
            "vip_level" to currentUser.vipLevel,
            "app_version" to appVersion,
        ),
    ),
)
```

`startSession()` 会调用 `/init`，拿到 visitor token，并用同一个 token 连接 Centrifugo。后续 REST 和实时消息鉴权都由 SDK 内部处理。

### 3. 监听消息和状态

```kotlin
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job

private var eventsJob: Job? = null

eventsJob = lifecycleScope.launch {
    HermesLiveChat.events.collect { event ->
        when (event) {
            is HermesLiveChatEvent.ConnectionStateChanged -> {
                renderConnectionState(event.state)
            }
            is HermesLiveChatEvent.MessageReceived -> {
                appendMessage(event.message)
            }
            is HermesLiveChatEvent.ConversationUpdated -> {
                updateConversation(event.conversation)
            }
            is HermesLiveChatEvent.MessageRead -> {
                markMessageRead(event.messageId, event.readAt)
            }
            is HermesLiveChatEvent.Error -> {
                showLivechatError(event.error)
            }
        }
    }
}
```

聊天页销毁时取消业务侧订阅：

```kotlin
eventsJob?.cancel()
```

### 4. 发送消息

```kotlin
try {
    val message = HermesLiveChat.sendText("你好，我想咨询订单问题")
    appendMessage(message)
} catch (error: HermesLiveChatException) {
    showLivechatError(error)
}
```

发送图片：

```kotlin
HermesLiveChat.sendImage(
    bytes = imageBytes,
    mimeType = "image/jpeg",
    filename = "order.jpg",
)
```

拉历史和已读：

```kotlin
val conversationId = HermesLiveChat.currentConversationId
if (conversationId != null) {
    val messages = HermesLiveChat.history(
        conversationId = conversationId,
        limit = 50,
    )

    messages.lastOrNull()?.let { message ->
        HermesLiveChat.markRead(
            conversationId = conversationId,
            messageId = message.uuid,
        )
    }
}
```

## 常见使用场景

### 绑定业务用户

有登录态的 App 应传稳定的 `customerId`。同一个 `customerId` 会复用同一个 LiveChat contact 和历史会话：

```kotlin
VisitorIdentity(
    customerId = currentUser.stableLivechatId,
    name = currentUser.name,
    email = currentUser.email,
    locale = "zh-CN",
)
```

不要给所有匿名用户传同一个兜底 ID。匿名用户可以不传 `customerId`，由 LiveChat 生成 visitor。

### 上传业务上下文

可通过 `attrs` 传会员等级、订单号、App 版本等上下文，方便客服识别问题：

```kotlin
VisitorIdentity(
    customerId = currentUser.stableLivechatId,
    attrs = mapOf(
        "order_id" to orderId,
        "vip_level" to currentUser.vipLevel,
        "app_version" to appVersion,
    ),
)
```

### 测试环境使用 HTTP

如果 `baseUrl` 是 `http://...`，必须配置 `android:usesCleartextTraffic="true"`。如果只允许指定域名明文访问，可以改用 Android Network Security Config。

### 只使用能力层，不使用默认 UI

业务 App 可以完全不调用 `HermesLiveChatActivity.open()`，只使用 `prefetchWelcome()`、`startSession()`、`sendText()`、`events` 等 API 自行渲染聊天页。

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
| `HermesLiveChat.configure(context, config)` | 初始化 SDK | 使用 `baseUrl`、`appKey`、可选 `realtimeUrl` |
| `HermesLiveChat.prefetchWelcome(locale)` | 拉欢迎语 | 不创建 visitor，不连接 WebSocket |
| `HermesLiveChat.startSession(identity)` | 创建或续签会话 | 调 `/init`，拿 visitor token，连接 realtime |
| `HermesLiveChat.sendText(text, conversationId)` | 发送文本 | `conversationId` 可不传，默认使用当前会话 |
| `HermesLiveChat.sendImage(bytes, mimeType, filename, conversationId)` | 发送图片 | SDK 先 presign，再上传，再发消息 |
| `HermesLiveChat.history(conversationId, afterId, limit)` | 拉历史 | 可用于打开页面恢复历史或断线补拉 |
| `HermesLiveChat.markRead(conversationId, messageId)` | 标记已读 | 通常在收到非 visitor 消息后调用 |
| `HermesLiveChat.events` | 事件流 | 监听连接状态、消息、会话更新、已读、错误 |
| `HermesLiveChat.disconnect()` | 断开 realtime | 不清空本地 session |
| `HermesLiveChat.destroy()` | 清理 SDK 内存状态 | 切租户、切账号或退出时使用 |
| `HermesLiveChatActivity.open(...)` | 打开默认聊天页 | 最低成本接入入口 |

## 生命周期和 session

- SDK 会把 visitor session 按 `appKey` 存在 `SharedPreferences`。
- `currentConversationId` 会在发消息、拉历史、收到实时事件时更新。
- visitor token 临近过期时，发送消息、拉历史、已读等操作会自动重走 `/init` 续签。
- `disconnect()` 只断开 realtime，不清空本地 session。
- `destroy()` 会断开 realtime，并清空 SDK 内存状态；重新使用前需要再次 `configure()`。
- Android 宿主 App 如果需要后台断开 / 前台重连策略，可以在自己的 lifecycle 中调用 `disconnect()` 和 `startSession(identity)`。

## 错误处理

能力层 API 会抛出 `HermesLiveChatException`：

```kotlin
try {
    HermesLiveChat.sendText("hello")
} catch (error: HermesLiveChatException) {
    when (error.error) {
        HermesLiveChatError.NOT_CONFIGURED -> show("请先初始化客服")
        HermesLiveChatError.CHANNEL_DISABLED -> show("客服渠道已禁用")
        HermesLiveChatError.ORG_DISABLED -> show("机构未开通在线客服")
        HermesLiveChatError.TOKEN_EXPIRED -> show("会话已过期，请重试")
        HermesLiveChatError.NETWORK -> show("网络异常，请稍后重试")
        else -> show(error.message ?: "发送失败")
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

## 代码混淆

SDK 默认无需额外 consumer ProGuard 规则。debug 构建无需额外配置。

如果宿主 App 开启 R8 后遇到 `centrifuge-java`、OkHttp、Kotlin coroutine 或 JSON 反射相关问题，先保留对应三方库，并把错误堆栈反馈给 SDK 维护方补充 `consumer-rules.pro`。

## 本地构建 SDK

```bash
cd sdk/android
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools \
./gradlew :hermes-livechat:assembleDebug
```

Lint：

```bash
./gradlew :hermes-livechat:lintDebug
```
