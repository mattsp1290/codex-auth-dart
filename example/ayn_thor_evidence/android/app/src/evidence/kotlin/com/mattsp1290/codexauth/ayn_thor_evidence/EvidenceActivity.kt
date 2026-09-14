package com.mattsp1290.codexauth.ayn_thor_evidence

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Evidence-only private command/result bridge. No intent extras are accepted. */
class EvidenceActivity : MainActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codex_auth/evidence_state_v1")
            .setMethodCallHandler { call, result ->
                executor.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "consumeCommand" -> consumeCommand()
                            "writeResult" -> {
                                val raw = call.argument<String>("result")
                                if (raw == null || raw.length > maxChars) throw IllegalArgumentException()
                                writeResult(raw)
                            }
                            "readCheckpoint" -> readCheckpoint()
                            "writeCheckpoint" -> {
                                val raw = call.argument<String>("checkpoint")
                                if (raw == null || raw.length > maxChars) throw IllegalArgumentException()
                                writeCheckpoint(raw)
                            }
                            "clearCheckpoint" -> clearCheckpoint()
                            else -> null
                        }
                        runOnUiThread {
                            if (call.method !in methods) result.notImplemented()
                            else result.success(value)
                        }
                    } catch (_: IllegalArgumentException) {
                        runOnUiThread { result.error("invalid", null, null) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("state", null, null) }
                    }
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

    private fun readCheckpoint(): String? {
        val checkpoint = File(filesDir, checkpointName)
        if (!checkpoint.exists() || checkpoint.length() > maxChars.toLong()) return null
        return checkpoint.readText(Charsets.UTF_8)
    }

    private fun writeCheckpoint(raw: String): Boolean {
        val target = File(filesDir, checkpointName)
        val temporary = File(filesDir, "$checkpointName.tmp")
        temporary.writeText(raw, Charsets.UTF_8)
        if (!temporary.renameTo(target)) {
            temporary.delete()
            return false
        }
        return true
    }

    private fun clearCheckpoint(): Boolean =
        !File(filesDir, checkpointName).exists() || File(filesDir, checkpointName).delete()

    companion object {
        private const val commandName = "evidence-command.json"
        private const val resultName = "evidence-result.json"
        private const val checkpointName = "evidence-checkpoint.json"
        private const val maxChars = 32768
        private val methods = setOf(
            "consumeCommand",
            "writeResult",
            "readCheckpoint",
            "writeCheckpoint",
            "clearCheckpoint",
        )
        private val executor = Executors.newSingleThreadExecutor()
    }
}
