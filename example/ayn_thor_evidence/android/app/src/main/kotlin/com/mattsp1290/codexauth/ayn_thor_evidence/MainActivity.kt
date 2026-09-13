package com.mattsp1290.codexauth.ayn_thor_evidence

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = DurableSecureRecordStore(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codex_auth/durable_record_v1")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> result.success(store.read())
                        "commit" -> {
                            val value = call.argument<String>("value")
                            if (value == null || value.length > DurableSecureRecordStore.maxEnvelopeChars) {
                                result.error("invalid", null, null)
                            } else if (store.commit(value)) result.success(true)
                            else result.error("commit", null, null)
                        }
                        "clear" -> if (store.clear()) result.success(true) else result.error("clear", null, null)
                        else -> result.notImplemented()
                    }
                } catch (_: DurableSecureRecordStore.CorruptRecordException) {
                    result.error("corrupt", null, null)
                } catch (_: Exception) {
                    result.error("storage", null, null)
                }
            }
    }
}
