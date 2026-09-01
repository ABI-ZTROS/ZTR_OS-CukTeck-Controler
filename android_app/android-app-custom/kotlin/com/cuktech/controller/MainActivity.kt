package com.cuktech.controller

import android.content.ActivityNotFoundException
import android.content.Intent
import android.util.Log
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.cuktech.controller/root_shell"
    private val rootShell by lazy { RootShell() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ========= 新增：非阻塞探测（推荐） =========
                    "probeRoot" -> {
                        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 5000L
                        // 不能阻塞主线程 → 丢给 lifecycleScope + IO
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val probe = rootShell.probeRoot(timeoutMs)
                                val json = probe.toJson().toString()
                                withContext(Dispatchers.Main) { pending.success(json) }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) {
                                    pending.error("PROBE_ERROR", t.message, null)
                                }
                            }
                        }
                    }
                    // ========= 新增：非阻塞命令执行 =========
                    "runCommandAsync" -> {
                        val command = call.argument<String>("command") ?: ""
                        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 8000L
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val out = rootShell.runCommandSuspend(command, timeoutMs)
                                withContext(Dispatchers.Main) { pending.success(out) }
                            } catch (se: SecurityException) {
                                withContext(Dispatchers.Main) {
                                    pending.error("SECURITY", se.message, null)
                                }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) {
                                    pending.error("EXECUTION_FAILED", t.message, null)
                                }
                            }
                        }
                    }
                    // ========= 新增：非阻塞读取米家 DB =========
                    "readMiotDbAsync" -> {
                        val dbPath = call.argument<String>("dbPath")
                            ?: RootShellConstants.MIUI_DB_PATH
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val deferred = rootShell.readMiotDb(dbPath)
                                val out = deferred.await()
                                withContext(Dispatchers.Main) { pending.success(out) }
                            } catch (se: SecurityException) {
                                withContext(Dispatchers.Main) {
                                    pending.error("SECURITY", se.message, null)
                                }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) {
                                    pending.error("EXECUTION_FAILED", t.message, null)
                                }
                            }
                        }
                    }
                    // ========= 新增：打开 KernelSU / Magisk / APatch 管理器 App =========
                    "openRootManager" -> {
                        val managerKey = call.argument<String>("manager") ?: "auto"
                        try {
                            val intent = buildRootManagerIntent(managerKey)
                            if (intent != null) {
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: ActivityNotFoundException) {
                            result.error("NOT_FOUND", "找不到 $managerKey 管理器 App", null)
                        } catch (t: Throwable) {
                            result.error("OPEN_FAIL", t.message, null)
                        }
                    }
                    // ========= 兼容：旧同步 checkRoot（仍然不建议） =========
                    "checkRoot" -> {
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val ok = rootShell.checkRoot()
                                withContext(Dispatchers.Main) { pending.success(ok) }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) { pending.success(false) }
                            }
                        }
                    }
                    // ========= 兼容：旧同步 runCommand =========
                    "runCommand" -> {
                        val command = call.argument<String>("command") ?: ""
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val output = rootShell.runCommandSuspend(command, 8000L)
                                withContext(Dispatchers.Main) { pending.success(output) }
                            } catch (se: SecurityException) {
                                withContext(Dispatchers.Main) {
                                    pending.error("SECURITY", se.message, null)
                                }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) {
                                    pending.error("EXECUTION_FAILED", t.message, null)
                                }
                            }
                        }
                    }
                    // ========= 兼容：旧同步 readMiotDb =========
                    "readMiotDb" -> {
                        val dbPath = call.argument<String>("dbPath")
                            ?: RootShellConstants.MIUI_DB_PATH
                        val pending = result.pending()
                        lifecycleScope.launch(Dispatchers.IO) {
                            try {
                                val deferred = rootShell.readMiotDb(dbPath)
                                val out = deferred.await()
                                withContext(Dispatchers.Main) { pending.success(out) }
                            } catch (se: SecurityException) {
                                withContext(Dispatchers.Main) {
                                    pending.error("SECURITY", se.message, null)
                                }
                            } catch (t: Throwable) {
                                withContext(Dispatchers.Main) {
                                    pending.error("EXECUTION_FAILED", t.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 根据 managerKey 构建启动对应 root 管理器 App 的 Intent。
     * auto 模式下优先匹配 detectRootManager 当前命中的。
     */
    private fun buildRootManagerIntent(managerKey: String): Intent? {
        val resolved = if (managerKey == "auto") {
            rootShell.detectRootManager().key
        } else managerKey
        val pkgCandidates: List<String> = when (resolved) {
            "kernelsu" -> listOf(
                "me.weishu.kernelsu",                  // KernelSU 官方包名
                "com.topjohnwu.magisk",                // 某些 fork 会复用
            )
            "magisk" -> listOf(
                "com.topjohnwu.magisk",                // Magisk (Canary/Stable)
                "io.github.huskydg.magisk",            // Magisk-Lite / Kitsune Mask
            )
            "apatch" -> listOf(
                "me.bmax.apatch",                      // APatch 官方包名
            )
            else -> emptyList()
        }
        for (pkg in pkgCandidates) {
            try {
                val launch = packageManager.getLaunchIntentForPackage(pkg)
                if (launch != null) {
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    return launch
                }
            } catch (_: Throwable) {}
        }
        // 兜底：KernelSU/Magisk 管理器市场搜索
        return null.also {
            Log.w("MainActivity", "buildRootManagerIntent: 未找到 $resolved 管理器的安装包")
        }
    }
}
