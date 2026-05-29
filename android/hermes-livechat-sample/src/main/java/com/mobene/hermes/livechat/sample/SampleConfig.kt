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
    )

    val environments: List<Environment> = listOf(
        Environment(
            name = "测试",
            description = "hermes-test.financifyx.com",
            baseUrl = "https://hermes-test.financifyx.com/api",
            realtimeUrl = "wss://hermes-test.financifyx.com/api/connection/websocket",
            appKey = "app_019e5ed46ccb74cf885dd5bbecf3bde7",
            secretKey = "sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0",
        ),
        Environment(
            name = "生产",
            description = "hermesomni.com",
            baseUrl = "https://hermesomni.com/api",
            realtimeUrl = "wss://hermesomni.com/api/connection/websocket",
            appKey = "app_019e5ed46ccb74cf885dd5bbecf3bde7",
            secretKey = "sk_Gizb1OlpD653G-Dbsp6A8K0D4NGrY3p7vpcSvxScFd0",
        ),
    )

    const val defaultEnvironmentIndex: Int = 0

    fun randomCustomerId(): String =
        "android-demo-${UUID.randomUUID().toString().replace("-", "").take(8)}"
}
