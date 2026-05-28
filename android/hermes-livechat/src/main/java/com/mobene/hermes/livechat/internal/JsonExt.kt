package com.mobene.hermes.livechat.internal

import org.json.JSONObject

internal fun JSONObject.optStringOrNull(name: String): String? {
    if (!has(name) || isNull(name)) return null
    return optString(name).takeIf { it.isNotEmpty() }
}

internal fun JSONObject.optLongOrNull(name: String): Long? {
    if (!has(name) || isNull(name)) return null
    return optLong(name)
}

internal fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    val value = get(key)
    if (value == JSONObject.NULL) null else value
}

internal fun JSONObject.toStringMap(): Map<String, String> = keys().asSequence().associateWith { key ->
    get(key).toString()
}
