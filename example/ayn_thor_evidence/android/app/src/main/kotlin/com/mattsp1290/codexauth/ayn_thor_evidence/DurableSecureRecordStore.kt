package com.mattsp1290.codexauth.ayn_thor_evidence

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** A deliberately narrow encrypted envelope driver; it never logs plaintext. */
class DurableSecureRecordStore(context: Context) {
    private val preferences = context.getSharedPreferences("codex_auth_durable_v1", Context.MODE_PRIVATE)

    fun read(): String? {
        val encoded = preferences.getString(recordKey, null) ?: return null
        if (encoded.length > maxStoredChars) throw CorruptRecordException()
        val bytes = try { Base64.decode(encoded, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { throw CorruptRecordException() }
        if (bytes.size < nonceBytes + tagBytes || bytes.size > maxCipherBytes) throw CorruptRecordException()
        val nonce = bytes.copyOfRange(0, nonceBytes)
        val ciphertext = bytes.copyOfRange(nonceBytes, bytes.size)
        val plain = try {
            Cipher.getInstance(transformation).run {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(tagBits, nonce))
                updateAAD(aad)
                doFinal(ciphertext)
            }
        } catch (_: Exception) { throw CorruptRecordException() }
        if (plain.size > maxEnvelopeChars) throw CorruptRecordException()
        return try { String(plain, StandardCharsets.UTF_8) } catch (_: Exception) { throw CorruptRecordException() }
    }

    fun commit(value: String): Boolean {
        if (value.length > maxEnvelopeChars) return false
        val nonce = ByteArray(nonceBytes).also { SecureRandom().nextBytes(it) }
        val ciphertext = Cipher.getInstance(transformation).run {
            init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(tagBits, nonce))
            updateAAD(aad)
            doFinal(value.toByteArray(StandardCharsets.UTF_8))
        }
        val joined = nonce + ciphertext
        return preferences.edit().putString(recordKey, Base64.encodeToString(joined, Base64.NO_WRAP)).commit()
    }

    fun clear(): Boolean = preferences.edit().remove(recordKey).commit()

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return generator.generateKey()
    }

    class CorruptRecordException : Exception()

    companion object {
        const val maxEnvelopeChars = 32768
        private const val maxStoredChars = 65536
        private const val maxCipherBytes = 49152
        private const val nonceBytes = 12
        private const val tagBytes = 16
        private const val tagBits = 128
        private const val transformation = "AES/GCM/NoPadding"
        private const val keyAlias = "codex_auth_durable_record_v1"
        private const val recordKey = "record"
        private val aad = "codex-auth-dart:state-envelope:v1".toByteArray(StandardCharsets.UTF_8)
    }
}
