package com.cuktech.controller

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.cuktech.controller/root_shell"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val rootShell = RootShell()
                when (call.method) {
                    "checkRoot" -> {
                        result.success(rootShell.checkRoot())
                    }
                    "runCommand" -> {
                        val command = call.argument<String>("command") ?: ""
                        try {
                            val output = rootShell.runCommand(command)
                            result.success(output)
                        } catch (e: SecurityException) {
                            result.error("SECURITY", e.message, null)
                        } catch (e: Exception) {
                            result.error("EXECUTION_FAILED", e.message, null)
                        }
                    }
                    "readMiotDb" -> {
                        val dbPath = call.argument<String>("dbPath")
                            ?: RootShellConstants.MIUI_DB_PATH
                        try {
                            val output = rootShell.readMiotDb(dbPath)
                            result.success(output)
                        } catch (e: SecurityException) {
                            result.error("SECURITY", e.message, null)
                        } catch (e: Exception) {
                            result.error("EXECUTION_FAILED", e.message, null)
                        }
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }
}
