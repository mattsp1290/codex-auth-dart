package com.mattsp1290.codexauth.ayn_thor_evidence

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Evidence-only private command/result bridge. No intent extras are accepted. */
class EvidenceActivity : MainActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codex_auth/evidence_state_v1")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "consumeCommand" -> result.success(consumeCommand())
                        "writeResult" -> {
                            val raw = call.argument<String>("result")
                            if (raw == null || raw.length > maxChars) result.error("invalid", null, null)
                            else result.success(writeResult(raw))
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("state", null, null)
                }
            }
    }

    private fun consumeCommand(): String? {
        val command = File(filesDir, commandName)
        if (!command.exists() || command.length() > maxChars.toLong()) return null
        val raw = command.readText(Charsets.UTF_8)
        if (!command.delete()) throw IllegalStateException()
        return raw
    }

    private fun writeResult(raw: String): Boolean {
        val target = File(filesDir, resultName)
        val temporary = File(filesDir, "$resultName.tmp")
        temporary.writeText(raw, Charsets.UTF_8)
        if (!temporary.renameTo(target)) {
            temporary.delete()
            return false
        }
        return true
    }

    companion object {
        private const val commandName = "evidence-command.json"
        private const val resultName = "evidence-result.json"
        private const val maxChars = 32768
    }
}
