# Hermes LiveChat Android Sample App

`hermes-livechat-sample` 是 Android SDK 的最小宿主测试 App，用于在真机或模拟器上验证默认聊天页。

## 默认配置

默认配置写在 `src/main/java/com/mobene/hermes/livechat/sample/MainActivity.kt`：

| 参数 | 默认值 | 必填 |
|---|---|---|
| `baseUrl` | `https://hermes-test.financifyx.com/api` | 是 |
| `realtimeUrl` | `wss://hermes-test.financifyx.com/api/connection/websocket` | 否，留空时 SDK 从 `baseUrl` 自动推导 |
| `appKey` | `app_019e5ed46ccb74cf885dd5bbecf3bde7` | 是 |
| `secretKey` | `sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0` | 否，仅用于 sample 本地签 `identity_token` |
| `customerId` | `android-test-user` | 否 |

首屏可以手动修改这些参数。点击“打开客服”后，sample app 会初始化 `HermesLiveChat` 并打开默认聊天页。

`secretKey` 只用于验证管理端 `is_auth=1` 的签名模式，正式 App 不应内置 Secret Key；生产接入应由客户 App Backend 生成短期 `identity_token` 后传给 SDK。

`baseUrl` 是 livechat 公网根挂载点，可以带网关子路径前缀（例如 `https://hermes-test.financifyx.com/api`，由 hermes-gateway 在该子路径下挂载 livechat 服务）。SDK 内部会在 `baseUrl` 后再拼 `/api/livechat/v1/...`，请不要将 `baseUrl` 写到 `/api/livechat/v1` 这一层。

## 构建

在 `sdk/android` 目录执行：

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools \
./gradlew :hermes-livechat-sample:assembleDebug
```

Debug APK 输出位置：

```bash
hermes-livechat-sample/build/outputs/apk/debug/hermes-livechat-sample-debug.apk
```

## 安装

```bash
adb install -r hermes-livechat-sample/build/outputs/apk/debug/hermes-livechat-sample-debug.apk
```

## 验证项

- 打开聊天页能看到欢迎语。
- 进入聊天页后能创建或续签 visitor session。
- 文本消息能发送成功。
- 能收到实时下行消息。
- 退出聊天页后再次进入，能恢复当前会话历史。
