package com.mattsp1290.codexauth.ayn_thor_evidence

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

open class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = DurableSecureRecordStore(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codex_auth/durable_record_v1")
            .setMethodCallHandler { call, result ->
                executor.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "read" -> store.read()
                            "commit" -> {
                                val record = call.argument<String>("value")
                                if (record == null || record.length > DurableSecureRecordStore.maxEnvelopeChars) {
                                    throw IllegalArgumentException()
                                }
                                if (!store.commit(record)) throw CommitException()
                                true
                            }
                            "clear" -> {
                                if (!store.clear()) throw ClearException()
                                true
                            }
                            else -> null
                        }
                        runOnUiThread {
                            if (call.method !in setOf("read", "commit", "clear")) result.notImplemented()
                            else result.success(value)
                        }
                    } catch (_: IllegalArgumentException) {
                        runOnUiThread { result.error("invalid", null, null) }
                    } catch (_: CommitException) {
                        runOnUiThread { result.error("commit", null, null) }
                    } catch (_: ClearException) {
                        runOnUiThread { result.error("clear", null, null) }
                    } catch (_: DurableSecureRecordStore.CorruptRecordException) {
                        runOnUiThread { result.error("corrupt", null, null) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("storage", null, null) }
                    }
                }
            }
    }

    private class CommitException : Exception()
    private class ClearException : Exception()

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
    }
}
