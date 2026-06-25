package com.mobene.hermes.livechat.internal

/**
 * 消息内容类型枚举。
 *
 * 后端在消息体的 `content_type` 字段下发字符串，这里用枚举收敛，避免在 UI 层散落
 * `contentType == "image"` 这类裸字符串比较。每个枚举项携带其对应的后端原始值 [raw]。
 */
enum class MessageContentType(
    /** 后端 `content_type` 字段对应的原始字符串值。 */
    val raw: String,
) {
    /** 纯文本 / 富文本（markdown 串），是 bot、客服、系统提示的主要载体。 */
    TEXT("text"),

    /** 图片消息：图片地址在 `content.url`，正文文案通常为空。 */
    IMAGE("image"),

    /** 文件消息：附件类消息。 */
    FILE("file"),

    /** 欢迎语：会话首条引导文案，同样走文本渲染。 */
    WELCOME("welcome"),

    /** 会话关闭提示。 */
    CLOSE("close"),

    /** 未识别类型：后端新增而 SDK 尚未跟进时的兜底。 */
    UNKNOWN("");

    companion object {
        /**
         * 把后端原始字符串映射为枚举；无法识别时返回 [UNKNOWN]。
         *
         * @param raw 后端 `content_type` 原始值，可能为 null。
         */
        fun fromRaw(raw: String?): MessageContentType =
            values().firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

/**
 * 消息发送方类型枚举。
 *
 * 本 SDK 的本地用户始终是「访客（visitor）」，因此 [isMine] 直接以是否访客判定。
 * 用枚举替代各处 `senderType == "visitor"` 的裸字符串比较。
 */
enum class MessageSenderType(
    /** 后端 `sender_type` 字段对应的原始字符串值。 */
    val raw: String,
) {
    /** 访客：即 App 内的本地用户自己，消息靠右、纯文本展示。 */
    VISITOR("visitor"),

    /** 人工客服。 */
    AGENT("agent"),

    /** 机器人 / 智能体。 */
    BOT("bot"),

    /** 系统消息（提示、状态变更等）。 */
    SYSTEM("system"),

    /** 未识别发送方：兜底，按「非本人」处理。 */
    UNKNOWN("");

    /**
     * 是否为本地用户（访客）自己发出的消息。
     *
     * 决定气泡左右对齐、是否纯文本展示（本人消息不渲染 markdown，与 widget 对齐）。
     */
    val isMine: Boolean
        get() = this == VISITOR

    companion object {
        /**
         * 把后端原始字符串映射为枚举；无法识别时返回 [UNKNOWN]。
         *
         * @param raw 后端 `sender_type` 原始值，可能为 null。
         */
        fun fromRaw(raw: String?): MessageSenderType =
            values().firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

/**
 * 消息展示规则（纯函数集合）。
 *
 * 把「展示哪段文案」「是否按 markdown 渲染」这类业务判定从 Activity 的 IO 层抽出，
 * 不依赖 Android 运行时，便于单元测试覆盖核心规则。
 */
object MessageDisplayRules {

    /**
     * 计算气泡要展示的文案。
     *
     * 规则（与既有行为保持一致）：
     * 1. `content.text` 去空白后非空 —— 直接展示该文案；
     * 2. 否则若是图片消息 —— 返回空串（由图片视图单独承载，不展示占位文字）；
     * 3. 其它类型且无文案 —— 返回 `[原始类型]` 占位（如 `[file]`），便于排查未渲染的消息。
     *
     * 之所以兜底用 [rawContentType] 而非枚举名，是为了在后端新增未知类型时仍能在界面
     * 看到真实类型字符串，而不是统一显示成 `[unknown]`。
     *
     * @param rawContentType 后端原始 `content_type`。
     * @param rawText 后端 `content.text` 原始值（未 trim）。
     */
    fun displayText(rawContentType: String, rawText: String): String {
        val trimmed = rawText.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return when (MessageContentType.fromRaw(rawContentType)) {
            MessageContentType.IMAGE -> ""
            else -> "[$rawContentType]"
        }
    }

    /**
     * 是否按 markdown 渲染该气泡。
     *
     * 仅渲染「非本人」（bot / 客服 / 系统）的文本：本人发送的消息保持纯文本，
     * 避免把用户原样输入的 `*` `_` 等字符误当成 markdown 标记，与 widget 行为一致。
     *
     * @param sender 消息发送方类型。
     */
    fun shouldRenderMarkdown(sender: MessageSenderType): Boolean = !sender.isMine
}
