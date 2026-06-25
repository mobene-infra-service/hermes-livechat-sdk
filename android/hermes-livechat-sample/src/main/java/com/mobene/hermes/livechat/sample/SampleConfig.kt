package com.mobene.hermes.livechat.sample

import java.util.UUID

object SampleConfig {
    data class Environment(
        val name: String,
        val description: String,
        val baseUrl: String,
        val realtimeUrl: String,
        val appKey: String,
        val secretKey: String,
        val bizToken: String,
    )

    val environments: List<Environment> = listOf(
        Environment(
            name = "测试",
            description = "hermes-test.financifyx.com",
            baseUrl = "https://hermes-test.financifyx.com/api",
            realtimeUrl = "wss://hermes-test.financifyx.com/api/connection/websocket",
            appKey = "app_019e5ed46ccb74cf885dd5bbecf3bde7",
            secretKey = "sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0",
            bizToken = "",
        ),
        Environment(
            name = "生产",
            description = "hermesomni.com",
            baseUrl = "https://hermesomni.com/api",
            realtimeUrl = "wss://hermesomni.com/api/connection/websocket",
            appKey = "app_019e5ed46ccb74cf885dd5bbecf3bde7",
            secretKey = "sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0",
            bizToken = "",
        ),
    )

    const val defaultEnvironmentIndex: Int = 0

    /**
     * 三端统一的 Markdown 验收样本文案。
     *
     * 这是「阶段0 公共准备」约定的 canonical 测试 bot 文本，三端（iOS / Android / Flutter）
     * 与 widget 用同一份，便于逐端肉眼比对渲染效果。验收时把这段文案从客服 / 机器人后台
     * 作为一条 bot 消息下发，确认以下三类均与 widget 一致：
     *
     * 1. 带 query 参数的链接：`link_token` 里的 `_` 不被吞、文案完整、可点击跳转；
     * 2. 内联图片：`![]()` 在气泡内渲染出图片；
     * 3. 列表 + 粗体/斜体/行内 code：缩进、配色与 widget `.md-body` 同源。
     */
    const val sampleBotMarkdown: String =
        "欢迎体验在线客服，下面验证 **Markdown** 渲染：\n\n" +
            "1. 带参链接：[点此加好友](https://applink.feishu.cn/client/chat/chatter/add_by_link?link_token=b3ah2f80-d6ba-4784-86a7-7da256b03aea)\n" +
            "2. *斜体* 与 `inline code`\n" +
            "3. 裸链接自动识别：https://hermesomni.com\n\n" +
            "内联图片：\n\n" +
            "![示例图片](https://picsum.photos/240/120)"

    fun randomCustomerId(): String =
        "android-demo-${UUID.randomUUID().toString().replace("-", "").take(8)}"
}
