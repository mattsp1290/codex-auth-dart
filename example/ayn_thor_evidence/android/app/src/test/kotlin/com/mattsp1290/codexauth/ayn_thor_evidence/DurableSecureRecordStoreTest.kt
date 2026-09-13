package com.mattsp1290.codexauth.ayn_thor_evidence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DurableSecureRecordStoreTest {
    @Test
    fun roundTripAndReconstructionUseOneAcknowledgedBackendValue() {
        val backend = FakeBackend()
        val first = DurableSecureRecordStore(backend, FramedCipher(), JvmEncoding())
        val second = DurableSecureRecordStore(backend, FramedCipher(), JvmEncoding())

        assertTrue(first.commit("finite-envelope"))
        assertEquals("finite-envelope", second.read())
        assertTrue(second.clear())
        assertNull(first.read())
    }

    @Test
    fun falseCommitAndClearAcknowledgementsPropagate() {
        val backend = FakeBackend(acknowledge = false)
        val store = DurableSecureRecordStore(backend, FramedCipher(), JvmEncoding())

        assertFalse(store.commit("finite-envelope"))
        assertFalse(store.clear())
    }

    @Test
    fun backendAndAuthenticationFailuresPropagateWithoutStoredValues() {
        val backend = FakeBackend()
        val store = DurableSecureRecordStore(backend, FramedCipher(), JvmEncoding())
        assertTrue(store.commit("finite-envelope"))
        backend.throwOnRead = true
        assertThrows(IllegalStateException::class.java) { store.read() }
        backend.throwOnRead = false
        backend.value = "AA=="
        assertThrows(DurableSecureRecordStore.CorruptRecordException::class.java) {
            store.read()
        }
    }
}

private class FakeBackend(
    private val acknowledge: Boolean = true,
) : DurableRecordBackend {
    var value: String? = null
    var throwOnRead = false

    override fun read(): String? {
        if (throwOnRead) throw IllegalStateException()
        return value
    }

    override fun commit(value: String): Boolean {
        if (acknowledge) this.value = value
        return acknowledge
    }

    override fun clear(): Boolean {
        if (acknowledge) value = null
        return acknowledge
    }
}

private class FramedCipher : DurableRecordCipher {
    override fun encrypt(value: ByteArray): ByteArray =
        ByteArray(12) + value + ByteArray(16)

    override fun decrypt(value: ByteArray): ByteArray =
        value.copyOfRange(12, value.size - 16)
}

private class JvmEncoding : DurableRecordEncoding {
    override fun encode(value: ByteArray): String =
        java.util.Base64.getEncoder().encodeToString(value)

    override fun decode(value: String): ByteArray =
        java.util.Base64.getDecoder().decode(value)
}
