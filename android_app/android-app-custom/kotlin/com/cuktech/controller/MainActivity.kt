package com.cuktech.controller

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    private val channelName = "com.cuktech.controller/root_shell"
    private val rootShell by lazy { RootShell() }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * Safe result dispatcher.
     *
     * We intentionally avoid `result.pending()`:
     *   1) It exists only in newer `flutter_plugin_android_lifecycle` / embedding
     *      versions and breaks on CI ("Unresolved reference 'pending'").
     *   2) MethodChannel.Result can be called from any thread since Flutter 2.x.
     *      However, we still post to the main thread here to keep behaviour
     *      identical to the previous lifecycleScope + withContext(Main) version.
     *
     * The helper is also tolerant of the "result already sent" window: if a
     * call races with Flutter engine teardown we catch and log, never crash.
     */
    private fun MethodChannel.Result.postSuccess(value: Any?) = safe { success(value) }
    private fun MethodChannel.Result.postError(code: String, msg: String?, details: Any?) =
        safe { error(code, msg, details) }

    private fun MethodChannel.Result.safe(block: () -> Unit) {
        val activity: Activity? = this@MainActivity
        val runnable = Runnable {
            try {
                if (activity == null || activity.isFinishing || activity.isDestroyed) return@Runnable
                block()
            } catch (_: IllegalStateException) {
                // "Reply already submitted" — benign, ignore.
            } catch (t: Throwable) {
                Log.w("MainActivity", "MethodChannel result dispatch failed: ${t.message}")
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) runnable.run() else mainHandler.post(runnable)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ========= 非阻塞探测（推荐） =========
                    "probeRoot" -> {
                        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 5000L
                        lifecycleScope.launch(Dispatchers.IO) {
                            val outcome = try {
                                rootShell.probeRoot(timeoutMs).toJson().toString()
                            } catch (ce: CancellationException) { throw ce }
                            catch (t: Throwable) {
                                result.postError("PROBE_ERROR", t.message, null); return@launch
                            }
                            withContext(Dispatchers.Main) { result.postSuccess(outcome) }
                        }
                    }
                    // ========= 非阻塞命令执行 =========
                    "runCommandAsync" -> {
                        val command = call.argument<String>("command") ?: ""
                        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 8000L
                        lifecycleScope.launch(Dispatchers.IO) {
                            val out = try {
                                rootShell.runCommandSuspend(command, timeoutMs)
                            } catch (ce: CancellationException) { throw ce }
                            catch (se: SecurityException) {
                                result.postError("SECURITY", se.message, null); return@launch
                            } catch (t: Throwable) {
                                result.postError("EXECUTION_FAILED", t.message, null); return@launch
                            }
                            withContext(Dispatchers.Main) { result.postSuccess(out) }
                        }
                    }
                    // ========= 非阻塞读取米家 DB =========
                    "readMiotDbAsync" -> {
                        val dbPath = call.argument<String>("dbPath")
                            ?: RootShellConstants.MIUI_DB_PATH
                        lifecycleScope.launch(Dispatchers.IO) {
                            val out = try {
                                rootShell.readMiotDb(dbPath).await()
                            } catch (ce: CancellationException) { throw ce }
                            catch (se: SecurityException) {
                                result.postError("SECURITY", se.message, null); return@launch
                            } catch (t: Throwable) {
                                result.postError("EXECUTION_FAILED", t.message, null); return@launch
                            }
                            withContext(Dispatchers.Main) { result.postSuccess(out) }
                        }
                    }
                    // ========= 打开 Root 管理器 App =========
                    "openRootManager" -> {
                        val managerKey = call.argument<String>("manager") ?: "auto"
                        try {
                            val intent = buildRootManagerIntent(managerKey)
                            result.postSuccess(if (intent != null) {
                                startActivity(intent); true
                            } else false)
                        } catch (e: ActivityNotFoundException) {
                            result.postError("NOT_FOUND", "找不到 $managerKey 管理器 App", null)
                        } catch (t: Throwable) {
                            result.postError("OPEN_FAIL", t.message, null)
                        }
                    }
                    // ========= 兼容：旧同步 checkRoot =========
                    "checkRoot" -> {
                        lifecycleScope.launch(Dispatchers.IO) {
                            val ok = try { rootShell.checkRoot() }
                            catch (ce: CancellationException) { throw ce }
                            catch (_: Throwable) { false }
                            withContext(Dispatchers.Main) { result.postSuccess(ok) }
                        }
                    }
                    // ========= 兼容：旧同步 runCommand =========
                    "runCommand" -> {
                        val command = call.argument<String>("command") ?: ""
                        lifecycleScope.launch(Dispatchers.IO) {
                            val out = try {
                                rootShell.runCommandSuspend(command, 8000L)
                            } catch (ce: CancellationException) { throw ce }
                            catch (se: SecurityException) {
                                result.postError("SECURITY", se.message, null); return@launch
                            } catch (t: Throwable) {
                                result.postError("EXECUTION_FAILED", t.message, null); return@launch
                            }
                            withContext(Dispatchers.Main) { result.postSuccess(out) }
                        }
                    }
                    // ========= 兼容：旧同步 readMiotDb =========
                    "readMiotDb" -> {
                        val dbPath = call.argument<String>("dbPath")
                            ?: RootShellConstants.MIUI_DB_PATH
                        lifecycleScope.launch(Dispatchers.IO) {
                            val out = try {
                                rootShell.readMiotDb(dbPath).await()
                            } catch (ce: CancellationException) { throw ce }
                            catch (se: SecurityException) {
                                result.postError("SECURITY", se.message, null); return@launch
                            } catch (t: Throwable) {
                                result.postError("EXECUTION_FAILED", t.message, null); return@launch
                            }
                            withContext(Dispatchers.Main) { result.postSuccess(out) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun buildRootManagerIntent(managerKey: String): Intent? {
        val resolved = if (managerKey == "auto") {
            rootShell.detectRootManager().key
        } else managerKey
        val pkgCandidates: List<String> = when (resolved) {
            "kernelsu" -> listOf("me.weishu.kernelsu", "com.topjohnwu.magisk")
            "magisk"   -> listOf("com.topjohnwu.magisk", "io.github.huskydg.magisk")
            "apatch"   -> listOf("me.bmax.apatch")
            else       -> emptyList()
        }
        for (pkg in pkgCandidates) {
            try {
                val launch = packageManager.getLaunchIntentForPackage(pkg)
                if (launch != null) {
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    return launch
                }
            } catch (_: Throwable) { /* try next */ }
        }
        Log.w("MainActivity", "buildRootManagerIntent: 未找到 $resolved 管理器的安装包")
        return null
    }
}
