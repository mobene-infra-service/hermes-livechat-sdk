package com.mobene.hermes.livechat.internal

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.mobene.hermes.livechat.VisitorSession
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal data class StoredSession(
    val appKey: String,
    val visitorId: String,
    val contactId: Long,
    val token: String,
    val tokenExp: Long,
    val realtimeUrl: String?,
    val lastConversationId: String?,
)

internal fun StoredSession.toVisitorSession(defaultRealtimeUrl: String) = VisitorSession(
    visitorId = visitorId,
    contactId = contactId,
    tokenExp = tokenExp,
    realtimeUrl = realtimeUrl ?: defaultRealtimeUrl,
)

internal class SessionStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("hermes_livechat", Context.MODE_PRIVATE)
    private val crypto = SessionCrypto()

    fun load(appKey: String): StoredSession? {
        val encryptedKey = encryptedKey(appKey)
        prefs.getString(encryptedKey, null)?.let { raw ->
            return runCatching { parseSession(appKey, crypto.decrypt(raw)) }.getOrNull()
        }

        val legacyKey = legacyKey(appKey)
        val legacy = prefs.getString(legacyKey, null) ?: return null
        return runCatching { parseSession(appKey, legacy) }.getOrNull()?.also {
            if (saveEncrypted(it)) {
                prefs.edit().remove(legacyKey).apply()
            }
        }
    }

    fun save(session: StoredSession) {
        saveEncrypted(session)
    }

    private fun saveEncrypted(session: StoredSession): Boolean = runCatching {
        val json = JSONObject().apply {
            put("visitor_id", session.visitorId)
            put("contact_id", session.contactId)
            put("token", session.token)
            put("token_exp", session.tokenExp)
            putOpt("realtime_url", session.realtimeUrl)
            putOpt("last_conversation_id", session.lastConversationId)
        }
        prefs.edit()
            .putString(encryptedKey(session.appKey), crypto.encrypt(json.toString()))
            .remove(legacyKey(session.appKey))
            .apply()
        true
    }.getOrDefault(false)

    private fun parseSession(appKey: String, raw: String): StoredSession {
        val json = JSONObject(raw)
        return StoredSession(
            appKey = appKey,
            visitorId = json.getString("visitor_id"),
            contactId = json.getLong("contact_id"),
            token = json.getString("token"),
            tokenExp = json.getLong("token_exp"),
            realtimeUrl = json.optStringOrNull("realtime_url"),
            lastConversationId = json.optStringOrNull("last_conversation_id"),
        )
    }

    private fun legacyKey(appKey: String) = "session:$appKey"

    private fun encryptedKey(appKey: String) = "session:$appKey:v2"
}

private class SessionCrypto {
    private val alias = "hermes_livechat_session"

    fun encrypt(raw: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(raw.toByteArray(StandardCharsets.UTF_8))
        val packed = ByteArray(1 + iv.size + encrypted.size)
        packed[0] = iv.size.toByte()
        System.arraycopy(iv, 0, packed, 1, iv.size)
        System.arraycopy(encrypted, 0, packed, 1 + iv.size, encrypted.size)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun decrypt(raw: String): String {
        val packed = Base64.decode(raw, Base64.NO_WRAP)
        val ivSize = packed[0].toInt()
        val iv = packed.copyOfRange(1, 1 + ivSize)
        val encrypted = packed.copyOfRange(1 + ivSize, packed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
