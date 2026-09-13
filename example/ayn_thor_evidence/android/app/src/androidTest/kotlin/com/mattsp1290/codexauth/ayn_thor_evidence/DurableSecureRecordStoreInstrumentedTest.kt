package com.mattsp1290.codexauth.ayn_thor_evidence

import android.content.Context
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DurableSecureRecordStoreInstrumentedTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        clearState()
    }

    @After
    fun tearDown() = clearState()

    @Test
    fun encryptedRoundTripSurvivesReconstruction() {
        val first = DurableSecureRecordStore(context)
        val second = DurableSecureRecordStore(context)
        val envelope = "finite-envelope"

        assertTrue(first.commit(envelope))
        assertEquals(envelope, second.read())
        val stored = preferences().getString(DurableSecureRecordStore.recordKey, null)
        assertFalse(stored.orEmpty().contains(envelope))
        assertTrue(second.clear())
        assertNull(first.read())
    }

    @Test
    fun tamperAndKeyLossFailClosed() {
        val store = DurableSecureRecordStore(context)
        assertTrue(store.commit("finite-envelope"))
        val encoded = preferences()
            .getString(DurableSecureRecordStore.recordKey, null)!!
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        assertTrue(
            preferences().edit().putString(
                DurableSecureRecordStore.recordKey,
                Base64.encodeToString(bytes, Base64.NO_WRAP),
            ).commit(),
        )
        expectCorrupt {
            store.read()
        }

        assertTrue(store.commit("replacement-envelope"))
        keyStore().deleteEntry(DurableSecureRecordStore.keyAlias)
        expectCorrupt {
            DurableSecureRecordStore(context).read()
        }
    }

    private fun preferences() = context.getSharedPreferences(
        DurableSecureRecordStore.preferencesName,
        Context.MODE_PRIVATE,
    )

    private fun keyStore() =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun expectCorrupt(action: () -> Unit) {
        try {
            action()
            fail("expected closed corruption failure")
        } catch (_: DurableSecureRecordStore.CorruptRecordException) {
            // Expected closed failure; no stored value is rendered.
        }
    }

    private fun clearState() {
        preferences().edit().clear().commit()
        val store = keyStore()
        if (store.containsAlias(DurableSecureRecordStore.keyAlias)) {
            store.deleteEntry(DurableSecureRecordStore.keyAlias)
        }
    }
}
