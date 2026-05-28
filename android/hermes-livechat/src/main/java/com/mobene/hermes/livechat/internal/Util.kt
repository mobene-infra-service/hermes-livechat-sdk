package com.mobene.hermes.livechat.internal

import java.net.URLEncoder
import java.util.UUID

internal fun newClientMsgId(): String = UUID.randomUUID().toString().replace("-", "")

internal fun defaultImageFilename(mimeType: String): String =
    "image_${UUID.randomUUID().toString().replace("-", "")}.${imageExtension(mimeType)}"

private fun imageExtension(mimeType: String): String = when (mimeType.lowercase()) {
    "image/png" -> "png"
    "image/gif" -> "gif"
    else -> "jpg"
}

internal fun urlEncode(value: String): String = URLEncoder.encode(value, "UTF-8")
