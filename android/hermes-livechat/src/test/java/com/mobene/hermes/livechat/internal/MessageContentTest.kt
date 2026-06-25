package com.mobene.hermes.livechat.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [MessageContentType] / [MessageSenderType] / [MessageDisplayRules] 的纯函数单元测试。
 *
 * 这些规则不依赖 Android 运行时（无 Context / 无 JSONObject / 无网络），可在本地 JVM 直接跑，
 * 覆盖「类型映射」「展示文案兜底」「是否渲染 markdown」三类核心业务规则。
 */
class MessageContentTest {

    // ---- MessageContentType.fromRaw ----

    @Test
    fun `内容类型_已知字符串映射到对应枚举`() {
        assertEquals(MessageContentType.TEXT, MessageContentType.fromRaw("text"))
        assertEquals(MessageContentType.IMAGE, MessageContentType.fromRaw("image"))
        assertEquals(MessageContentType.FILE, MessageContentType.fromRaw("file"))
        assertEquals(MessageContentType.WELCOME, MessageContentType.fromRaw("welcome"))
        assertEquals(MessageContentType.CLOSE, MessageContentType.fromRaw("close"))
    }

    @Test
    fun `内容类型_未知或null回退到UNKNOWN`() {
        assertEquals(MessageContentType.UNKNOWN, MessageContentType.fromRaw("brand_new_type"))
        assertEquals(MessageContentType.UNKNOWN, MessageContentType.fromRaw(null))
        // 空串不应误命中 UNKNOWN.raw（约定空串语义仍是「未知」）
        assertEquals(MessageContentType.UNKNOWN, MessageContentType.fromRaw(""))
    }

    // ---- MessageSenderType.isMine ----

    @Test
    fun `发送方_访客判定为本人其余均非本人`() {
        assertTrue(MessageSenderType.fromRaw("visitor").isMine)
        assertFalse(MessageSenderType.fromRaw("agent").isMine)
        assertFalse(MessageSenderType.fromRaw("bot").isMine)
        assertFalse(MessageSenderType.fromRaw("system").isMine)
        // 未知发送方按「非本人」兜底，保证对方消息仍走 markdown 渲染
        assertFalse(MessageSenderType.fromRaw("anything_else").isMine)
        assertFalse(MessageSenderType.fromRaw(null).isMine)
    }

    // ---- MessageDisplayRules.displayText ----

    @Test
    fun `展示文案_有文本时优先展示并去除首尾空白`() {
        assertEquals("你好", MessageDisplayRules.displayText("text", "  你好  "))
        // 即便是图片类型，只要带了文案（如图片说明）也应展示
        assertEquals("配图说明", MessageDisplayRules.displayText("image", "配图说明"))
    }

    @Test
    fun `展示文案_图片无文案返回空串`() {
        assertEquals("", MessageDisplayRules.displayText("image", ""))
        assertEquals("", MessageDisplayRules.displayText("image", "   "))
    }

    @Test
    fun `展示文案_非图片无文案回退为原始类型占位`() {
        assertEquals("[file]", MessageDisplayRules.displayText("file", ""))
        assertEquals("[close]", MessageDisplayRules.displayText("close", "   "))
        // 未知类型保留真实原始字符串，便于线上排查
        assertEquals("[mystery]", MessageDisplayRules.displayText("mystery", ""))
    }

    // ---- MessageDisplayRules.shouldRenderMarkdown ----

    @Test
    fun `是否渲染markdown_仅非本人消息渲染`() {
        assertFalse(MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.VISITOR))
        assertTrue(MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.BOT))
        assertTrue(MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.AGENT))
        assertTrue(MessageDisplayRules.shouldRenderMarkdown(MessageSenderType.SYSTEM))
    }
}
