# Hermes LiveChat SDK

Hermes LiveChat SDK 用于在客户 App 内接入在线客服。当前仓库提供三端 SDK：

| SDK | 路径 | 适用 App | 包形态 |
|---|---|---|---|
| Flutter | [`sdk/flutter`](./flutter/README.md) | Flutter App | Dart package |
| Android | [`sdk/android`](./android/README.md) | 原生 Android App | Gradle library module |
| iOS | [`sdk/ios`](./ios/README.md) | 原生 iOS App | Swift Package |

三端协议一致：App 用公开 `app_key` 初始化，打开聊天入口时只拉欢迎语，用户首次发送消息前才调用 `/init` 获取 visitor token；后续 REST 和 Centrifugo realtime 都使用 visitor token。

## 接入前准备

后台或运营需要先提供：

| 参数 | 示例 | 说明 |
|---|---|---|
| `baseUrl` | `https://chat.example.com` | LiveChat 访客 REST API 地址。可带网关子路径前缀（例如 `https://hermes-test.financifyx.com/api`），SDK 内部会拼 `/api/livechat/v1/...`，不要写到该层 |
| `appKey` | `019e6335c04478838ef4f9418263d279` | 管理后台 App 渠道生成的公开 key |
| `realtimeUrl` | `wss://chat.example.com/connection/websocket` | 可选；不传时 SDK 从 `baseUrl` 自动推导 |
| `customerId` | `u_8f3a...` | 可选；业务侧稳定、不可枚举的用户标识 |

## Secret 验证配置

后台编辑 App 渠道时，开关名称是「Secret 验证」。App Secret 不是 SDK 参数，不能写进 Android / iOS / Flutter 客户端。它只在启用强身份校验时使用：

| 配置项 | 配置位置 | 说明 |
|---|---|---|
| `Secret 验证` (`is_auth`) | LiveChat 管理后台 App 渠道 | 关闭表示弱绑定模式；开启表示强身份签名校验 |
| `Secret Key` / `App Secret` | LiveChat 管理后台 App 渠道 | 创建或编辑 App 渠道时生成/配置，客户 App Backend 保存，客户端不保存 |
| `identity_token` | 客户 App Backend 签发 | 使用 App Secret 以 HS256 签发，客户端通过 `VisitorIdentity.identityToken` 传给 SDK |

默认「Secret 验证」关闭时，SDK 不需要客户 App Backend 签 token，不需要 App secret，也不需要 `X-Arke-Service-Token`。`Secret Key` 不能放进客户端。

如果管理端开启「Secret 验证」，客户 App Backend 必须用该 App 的 `Secret Key` 签发短期 HS256 `identity_token`，App 再通过 `VisitorIdentity.identityToken` 传给 SDK。LiveChat 后端验签通过后以 token claims 为准，客户端直接传的 `customerId/name/email` 只作为无签名模式的弱绑定字段。

推荐签发的 JWT claims：

```json
{
  "sub": "业务侧稳定用户ID",
  "customer_id": "业务侧稳定用户ID",
  "name": "用户昵称",
  "email": "user@example.com",
  "app_key": "<app_key>",
  "iat": 1778668800,
  "exp": 1778669100
}
```

`exp` 必填，建议 5 分钟内；`app_key` 如存在必须与 SDK 配置的 `appKey` 一致。

后台还必须为 App 渠道绑定并启用接待方案，否则 SDK 会收到 `70021` / `LC_RECEPTION_PLAN_NOT_FOUND` 一类错误：

- `channel_type`: `app`
- `channel_ref`: 对应 `appKey`
- `receive_mode`: `bot_only`
- `bot_code`: 可用的 LiveChat 接待机器人

## 核心流程

1. App 启动或业务模块初始化时调用 `configure(baseUrl, appKey, realtimeUrl?)`。
2. 用户打开咨询入口时调用 `prefetchWelcome(locale?)` 或打开默认聊天页。
3. 用户首次发送消息前 SDK 调用 `/init`，生成 visitor token 并连接 Centrifugo。
4. 文本、图片、历史和已读接口使用 visitor token。
5. token 临近过期时 SDK 静默续签。
6. 业务层监听 events 更新 UI。

## 文档入口

- Flutter 接入：[sdk/flutter/README.md](./flutter/README.md)
- Android 接入：[sdk/android/README.md](./android/README.md)
- iOS 接入：[sdk/ios/README.md](./ios/README.md)
