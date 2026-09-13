package com.mattsp1290.codexauth.ayn_thor_evidence

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal interface DurableRecordBackend {
    fun read(): String?
    fun commit(value: String): Boolean
    fun clear(): Boolean
}

internal interface DurableRecordCipher {
    fun encrypt(value: ByteArray): ByteArray
    fun decrypt(value: ByteArray): ByteArray
}

internal interface DurableRecordEncoding {
    fun encode(value: ByteArray): String
    fun decode(value: String): ByteArray
}

/** A deliberately narrow encrypted envelope driver; it never logs plaintext. */
class DurableSecureRecordStore internal constructor(
    private val backend: DurableRecordBackend,
    private val cipher: DurableRecordCipher,
    private val encoding: DurableRecordEncoding = AndroidBase64RecordEncoding(),
) {
    constructor(context: Context) : this(
        SharedPreferencesRecordBackend(context),
        AndroidKeystoreRecordCipher(),
    )

    fun read(): String? {
        val encoded = backend.read() ?: return null
        if (encoded.length > maxStoredChars) throw CorruptRecordException()
        val bytes = try {
            encoding.decode(encoded)
        } catch (_: IllegalArgumentException) {
            throw CorruptRecordException()
        }
        if (bytes.size < nonceBytes + tagBytes || bytes.size > maxCipherBytes) {
            throw CorruptRecordException()
        }
        val plain = try {
            cipher.decrypt(bytes)
        } catch (_: Exception) {
            throw CorruptRecordException()
        }
        if (plain.size > maxEnvelopeChars) throw CorruptRecordException()
        return try {
            String(plain, StandardCharsets.UTF_8)
        } catch (_: Exception) {
            throw CorruptRecordException()
        }
    }

    fun commit(value: String): Boolean {
        if (value.length > maxEnvelopeChars) return false
        val encrypted = cipher.encrypt(value.toByteArray(StandardCharsets.UTF_8))
        if (encrypted.size > maxCipherBytes) return false
        return backend.commit(encoding.encode(encrypted))
    }

    fun clear(): Boolean = backend.clear()

    class CorruptRecordException : Exception()

    companion object {
        const val maxEnvelopeChars = 32768
        internal const val preferencesName = "codex_auth_durable_v1"
        internal const val keyAlias = "codex_auth_durable_record_v1"
        internal const val recordKey = "record"
        private const val maxStoredChars = 65536
        private const val maxCipherBytes = 49152
        private const val nonceBytes = 12
        private const val tagBytes = 16
    }
}

private class AndroidBase64RecordEncoding : DurableRecordEncoding {
    override fun encode(value: ByteArray): String =
        Base64.encodeToString(value, Base64.NO_WRAP)

    override fun decode(value: String): ByteArray =
        Base64.decode(value, Base64.NO_WRAP)
}

private class SharedPreferencesRecordBackend(context: Context) : DurableRecordBackend {
    private val preferences = context.getSharedPreferences(
        DurableSecureRecordStore.preferencesName,
        Context.MODE_PRIVATE,
    )

    override fun read(): String? =
        preferences.getString(DurableSecureRecordStore.recordKey, null)

    override fun commit(value: String): Boolean = preferences.edit()
        .putString(DurableSecureRecordStore.recordKey, value)
        .commit()

    override fun clear(): Boolean = preferences.edit()
        .remove(DurableSecureRecordStore.recordKey)
        .commit()
}

private class AndroidKeystoreRecordCipher : DurableRecordCipher {
    override fun encrypt(value: ByteArray): ByteArray {
        val operation = Cipher.getInstance(transformation).apply {
            init(Cipher.ENCRYPT_MODE, key())
            updateAAD(aad)
        }
        val ciphertext = operation.doFinal(value)
        val nonce = operation.iv
        if (nonce.size != nonceBytes) throw IllegalStateException()
        return nonce + ciphertext
    }

    override fun decrypt(value: ByteArray): ByteArray {
        val nonce = value.copyOfRange(0, nonceBytes)
        val ciphertext = value.copyOfRange(nonceBytes, value.size)
        return Cipher.getInstance(transformation).run {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(tagBits, nonce))
            updateAAD(aad)
            doFinal(ciphertext)
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(DurableSecureRecordStore.keyAlias, null) as? SecretKey)?.let {
            return it
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                DurableSecureRecordStore.keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        private const val nonceBytes = 12
        private const val tagBits = 128
        private const val transformation = "AES/GCM/NoPadding"
        private val aad = "codex-auth-dart:state-envelope:v1"
            .toByteArray(StandardCharsets.UTF_8)
    }
}
