package com.cuktech.controller

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * RootShell v4 —— KernelSU 原生适配（不依赖 libsu）
 *
 * 核心设计：
 * ──────────────────────────────────────────────────────────────
 * KernelSU 和 Magisk 最大的不同在于：**KernelSU 默认没有 su 命令**。
 * KernelSU 的 root 入口是：
 *
 *   ① /data/adb/ksud debug su -c "cmd"   ← 万能钥匙，所有 KernelSU 版本
 *   ② /data/adb/ksu/bin/su -c "cmd"      ← KernelSU >= 0.9.5 提供的 su
 *   ③ su -c "cmd"                          ← 依赖 sucompat 或 Magisk 常规
 *
 * 我们按优先级依次尝试每个入口，直接用 Runtime.exec() 执行命令，
 * 简单、可靠、不搞花活。
 *
 * 成功的 su 入口会被缓存（workingSuEntryCache），后续命令直接用，
 * 不用每次重新探测。
 * ──────────────────────────────────────────────────────────────
 */
class RootShell {

    companion object {
        private const val TAG = "RootShell"

        /**
         * 按优先级排序的 su 入口。
         * 每个条目包含：名称（诊断用）、可执行路径、以及把命令转成 argv 的 lambda。
         */
        private val SU_ENTRIES = listOf<SuEntry>(
            // ① KernelSU 守护进程（万能钥匙，所有版本都有 ksud）
            SuEntry(
                name = "KernelSU ksud",
                executable = "/data/adb/ksud",
                argvFor = { cmd -> arrayOf("/data/adb/ksud", "debug", "su", "-c", cmd) },
            ),
            // ② KernelSU >= 0.9.5 提供的专用 su 二进制
            SuEntry(
                name = "KernelSU su bin",
                executable = "/data/adb/ksu/bin/su",
                argvFor = { cmd -> arrayOf("/data/adb/ksu/bin/su", "-c", cmd) },
            ),
            // ③ KernelSU sucompat 或 Magisk 的 /system/bin/su
            SuEntry(
                name = "/system/bin/su",
                executable = "/system/bin/su",
                argvFor = { cmd -> arrayOf("/system/bin/su", "-c", cmd) },
            ),
            // ④ 极旧设备路径
            SuEntry(
                name = "/system/xbin/su",
                executable = "/system/xbin/su",
                argvFor = { cmd -> arrayOf("/system/xbin/su", "-c", cmd) },
            ),
            // ⑤ 依赖 PATH（sucompat 或 Magisk 都可能把 su 放进 PATH）
            SuEntry(
                name = "PATH su",
                executable = "su",
                argvFor = { cmd -> arrayOf("su", "-c", cmd) },
            ),
        )

        private val ALLOWED_PREFIXES = listOf(
            "sqlite3 ", "id", "cp ", "chmod ", "cat ", "ls -la ", "ls ",
            "echo ", "rm ", "base64", "od -A", "od ", "stat ", "ksud ",
        )
    }

    // =================== 类型定义 ===================

    private data class SuEntry(
        val name: String,
        val executable: String,
        val argvFor: (String) -> Array<String>,
    )

    data class SuProbeOutcome(
        val entryName: String,
        val available: Boolean,
        val uid: Int?,
        val exitCode: Int?,
        val error: String?,
    )

    enum class RootManager(val key: String, val displayCn: String) {
        KERNEL_SU("kernelsu", "KernelSU"),
        MAGISK("magisk", "Magisk"),
        APATCH("apatch", "APatch"),
        UNKNOWN("unknown", "未知 su 管理器"),
        NONE("none", "未检测到 root 环境"),
    }

    data class ProbeResult(
        val ok: Boolean,
        val manager: RootManager,
        val suVersionText: String,
        val uid: Int?,
        val timeoutMs: Long,
        val suggestion: String,
        val rawError: String? = null,
        val detectionMethod: String = "",
        val probeDetails: List<SuProbeOutcome> = emptyList(),
    ) {
        fun toJson(): JSONObject {
            val j = JSONObject()
            j.put("ok", ok)
            j.put("state", stateKey())
            j.put("manager", manager.key)
            j.put("managerDisplay", manager.displayCn)
            j.put("suVersion", suVersionText)
            j.put("uid", uid ?: JSONObject.NULL)
            j.put("timeoutMs", timeoutMs)
            j.put("suggestion", suggestion)
            j.put("rawError", rawError ?: JSONObject.NULL)
            j.put("detectionMethod", detectionMethod)

            val arr = JSONArray()
            for (d in probeDetails) {
                arr.put(JSONObject().apply {
                    put("entry", d.entryName)
                    put("available", d.available)
                    put("uid", d.uid ?: JSONObject.NULL)
                    put("exitCode", d.exitCode ?: JSONObject.NULL)
                    put("error", d.error ?: JSONObject.NULL)
                })
            }
            j.put("probeDetails", arr)
            return j
        }

        private fun stateKey(): String = when {
            ok -> "available"
            manager == RootManager.NONE -> "none"
            rawError?.contains("TIMEOUT") == true -> "timeout"
            manager != RootManager.NONE && !ok -> "denied"
            rawError != null -> "error"
            else -> "denied"
        }
    }

    // =================== 运行时缓存 ===================

    /** 缓存上次成功的 su 入口，下次命令直接用，避免重复探测 */
    private val workingEntryCache = ConcurrentHashMap<String, SuEntry>()

    private fun cacheKey() = "default"

    // =================== 管理层探测 ===================

    /** 检测 root 管理器类型（物理痕迹优先，行为探测次之） */
    fun detectRootManager(): RootManager {
        // 1. KernelSU 专属：ksud 守护进程
        if (File("/data/adb/ksud").exists()) return RootManager.KERNEL_SU

        // 2. /proc/version 内核字符串标记
        if (readTextSafe("/proc/version").contains("kernelsu", ignoreCase = true))
            return RootManager.KERNEL_SU

        // 3. KernelSU su 二进制
        if (File("/data/adb/ksu/bin/su").exists()) return RootManager.KERNEL_SU

        // 4. Magisk 标记
        if (File("/data/adb/magisk").exists()) return RootManager.MAGISK

        // 5. APatch
        if (File("/data/adb/apd").exists() || File("/data/adb/apatch").exists())
            return RootManager.APATCH

        // 6. 通过 su -V 输出版本号判断
        val v = probeSuVersionText()
        val vl = v.lowercase()
        return when {
            vl.contains("kernelsu") || vl.contains("ksu") -> RootManager.KERNEL_SU
            vl.contains("magisk") -> RootManager.MAGISK
            vl.contains("apatch") || vl.contains("apd") -> RootManager.APATCH
            v.isNotBlank() -> RootManager.UNKNOWN
            else -> RootManager.NONE
        }
    }

    private fun probeSuVersionText(): String {
        for (entry in SU_ENTRIES) {
            if (!isEntryAvailable(entry)) continue
            for (flag in arrayOf("-V", "--version", "-v")) {
                try {
                    val p = Runtime.getRuntime().exec(arrayOf(entry.executable, flag))
                    val got = readAll(p, 500L).trim()
                    if (got.isNotBlank()) return got
                } catch (_: Throwable) {}
            }
        }
        return ""
    }

    /** 一个 su 入口是否物理可用（文件存在 或 在 PATH 中） */
    private fun isEntryAvailable(entry: SuEntry): Boolean {
        return if (entry.executable == "su") {
            try {
                val path = System.getenv("PATH") ?: ""
                path.split(':').any { File(it).resolve("su").exists() }
            } catch (_: Throwable) { false }
        } else {
            File(entry.executable).exists()
        }
    }

    // =================== 核心：su 探测 + 夺权 ===================

    /**
     * 非阻塞探测 root：依次尝试所有 su 入口，找到能成功执行 "id" 并返回 uid=0 的入口。
     *
     * @param timeoutMs 每个入口的最大等待时间（超时可能是授权弹窗没点）
     */
    suspend fun probeRoot(timeoutMs: Long = 5000L): ProbeResult =
        withContext(Dispatchers.IO) {
            val manager = detectRootManager()
            val suVer = probeSuVersionText()

            if (manager == RootManager.NONE) {
                return@withContext ProbeResult(
                    ok = false, manager = RootManager.NONE,
                    suVersionText = suVer, uid = null,
                    timeoutMs = timeoutMs,
                    suggestion = "设备上未检测到 KernelSU / Magisk / APatch。" +
                            "请先刷入 root（推荐 KernelSU）。",
                    detectionMethod = "none_detected",
                )
            }

            Log.i(TAG, "检测到 root 管理器: ${manager.displayCn}，开始探测 su 入口…")

            val details = mutableListOf<SuProbeOutcome>()
            var lastErr: String? = null

            for (entry in SU_ENTRIES) {
                val avail = isEntryAvailable(entry)
                if (!avail) {
                    details.add(SuProbeOutcome(entry.name, false, null, null, "not available"))
                    Log.d(TAG, "  ⏭ ${entry.name} → 不可用")
                    continue
                }

                Log.d(TAG, "  🔍 ${entry.name}…")
                val res = withTimeoutOrNull(timeoutMs) {
                    executeRaw(entry, "id", timeoutMs)
                }

                if (res == null) {
                    details.add(SuProbeOutcome(entry.name, true, null, null,
                        "TIMEOUT ${timeoutMs}ms — 授权弹窗未确认?"))
                    Log.w(TAG, "  ⏳ ${entry.name} → 超时")
                    lastErr = "TIMEOUT: ${entry.name}"
                    continue
                }

                details.add(SuProbeOutcome(
                    entryName = entry.name,
                    available = true,
                    uid = res.uid,
                    exitCode = res.exit,
                    error = res.errorMsg,
                ))

                if (res.exit == 0 && res.uid == 0) {
                    // ✅ 成功！缓存入口
                    workingEntryCache[cacheKey()] = entry
                    Log.i(TAG, "  ✅ ${entry.name} → uid=0")
                    return@withContext ProbeResult(
                        ok = true, manager = manager,
                        suVersionText = suVer, uid = 0,
                        timeoutMs = timeoutMs,
                        suggestion = buildSuccessSuggestion(manager, entry.name),
                        detectionMethod = "entry:${entry.name}",
                        probeDetails = details,
                    )
                }

                lastErr = "[${entry.name}] exit=${res.exit} uid=${res.uid} err=${res.errorMsg?.take(100)}"
                Log.d(TAG, "  ❌ ${entry.name} → $lastErr")
            }

            Log.w(TAG, "所有 su 入口均失败")
            ProbeResult(
                ok = false, manager = manager,
                suVersionText = suVer, uid = null,
                timeoutMs = timeoutMs,
                suggestion = buildDeniedSuggestion(manager),
                rawError = lastErr,
                detectionMethod = "all_failed",
                probeDetails = details,
            )
        }

    // =================== 运行时命令执行 ===================

    /**
     * 挂起函数：执行 root 命令，返回 stdout 字符串。
     * 自动使用缓存的成功入口，否则依次尝试所有入口。
     */
    suspend fun runCommandSuspend(command: String, timeoutMs: Long = 8000L): String {
        assertAllowed(command)
        return withContext(Dispatchers.IO) {
            // 1. 缓存命中
            val cached = workingEntryCache[cacheKey()]
            if (cached != null && isEntryAvailable(cached)) {
                val r = executeRaw(cached, command, timeoutMs)
                if (r.exit == 0) {
                    return@withContext r.stdout.ifBlank { r.stderr }
                }
                Log.w(TAG, "缓存入口失效（exit=${r.exit}），重新探测…")
            }

            // 2. 依次尝试
            for (entry in SU_ENTRIES) {
                if (!isEntryAvailable(entry)) continue
                val r = executeRaw(entry, command, timeoutMs)
                if (r.exit == 0) {
                    workingEntryCache[cacheKey()] = entry
                    Log.i(TAG, "✅ ${command.take(30)} 通过 ${entry.name} 执行成功")
                    return@withContext r.stdout.ifBlank { r.stderr }
                }
            }
            "ROOT_FAIL: all su entries failed for '${command.take(40)}'"
        }
    }

    /** 读取米家数据库（异步 Deferred），返回 base64 编码的 DB blob */
    fun readMiotDb(dbPath: String, timeoutMs: Long = 12000L): kotlinx.coroutines.Deferred<String> {
        val escaped = dbPath.replace("\"", "\\\"")
        val cmd = "cat \"$escaped\" | base64"
        assertAllowed(cmd)
        val scope = CoroutineScope(Dispatchers.IO)
        return scope.async { runCommandSuspend(cmd, timeoutMs) }
    }

    // =================== 老同步 API ===================

    fun checkRoot(): Boolean {
        return try {
            runCommandSync("id").contains("uid=0")
        } catch (_: Throwable) { false }
    }

    fun runCommand(command: String): String {
        assertAllowed(command)
        return runCommandSync(command)
    }

    private fun runCommandSync(command: String): String {
        return try {
            val scope = CoroutineScope(Dispatchers.IO)
            val def = scope.async { runCommandSuspend(command, 8000L) }
            def.get(10L, TimeUnit.SECONDS)
        } catch (t: Throwable) {
            "EXCEPTION: ${t.message}"
        }
    }

    // =================== 底层执行 ===================

    private data class RawResult(
        val stdout: String,
        val stderr: String,
        val exit: Int,
        val uid: Int?,        // 从 stdout 解析的 uid（仅 "id" 命令）
        val errorMsg: String?, // 方便诊断的错误摘要
    )

    /**
     * 用指定 su 入口执行命令，返回 RawResult。
     * 这是所有命令执行的最终底层。
     */
    private fun executeRaw(entry: SuEntry, cmd: String, timeoutMs: Long): RawResult {
        return try {
            val argv = entry.argvFor(cmd)
            val p = Runtime.getRuntime().exec(argv)
            val stdout = readAll(p, timeoutMs.coerceAtLeast(1000) - 500)
            val stderr = readErr(p, 500L)
            val exit = safeWaitFor(p)

            val uid = if (cmd == "id" || cmd.startsWith("id")) {
                "uid=([0-9]+)".toRegex().find(stdout)?.groupValues?.get(1)?.toIntOrNull()
            } else null

            val errMsg = when {
                exit != 0 && stderr.isNotBlank() -> stderr.take(200)
                exit != 0 -> "exit=$exit"
                exit == 0 && uid != null && uid != 0 -> "not root uid=$uid"
                else -> null
            }

            RawResult(stdout, stderr, exit, uid, errMsg)
        } catch (t: Throwable) {
            RawResult(
                stdout = "", stderr = "", exit = -1, uid = null,
                errorMsg = "EXCEPTION: ${t.javaClass.simpleName}: ${t.message}",
            )
        }
    }

    // =================== 工具函数 ===================

    private fun assertAllowed(cmd: String) {
        val c = cmd.trim()
        if (ALLOWED_PREFIXES.none { c.startsWith(it) }) {
            throw SecurityException("命令不在白名单: $c")
        }
    }

    private fun buildSuccessSuggestion(m: RootManager, entry: String) = when (m) {
        RootManager.KERNEL_SU -> "✅ 已通过 KernelSU 获得 root（uid=0），可读取米家数据库。" +
                "建议：在 KernelSU 管理器 → 超级用户 → 本 App → 自动响应设为「授予」。"
        RootManager.MAGISK -> "✅ 已通过 Magisk 获得 root（uid=0），可读取米家数据库。"
        RootManager.APATCH -> "✅ 已通过 APatch 获得 root（uid=0），可读取米家数据库。"
        else -> "✅ root 可用（入口：$entry）。"
    }

    private fun buildDeniedSuggestion(m: RootManager) = when (m) {
        RootManager.KERNEL_SU -> "❌ KernelSU 拒绝了 su 请求。请依次操作：\n" +
                "  ① 打开 KernelSU 管理器\n" +
                "  ② 点击「超级用户」标签\n" +
                "  ③ 找到「酷态科控制器」并进入详情\n" +
                "  ④ 确保开关为开启状态，「自动响应」设为「授予」\n" +
                "  ⑤ 回到本 App，点击 Root 徽章「重试」"
        RootManager.MAGISK -> "❌ Magisk 拒绝了 su 请求。请在 Magisk → 超级用户中改为「已授予」。"
        RootManager.APATCH -> "❌ APatch 拒绝了 su 请求。请在 APatch 中授权本 App。"
        else -> "❌ su 执行失败。请确认 root 管理器已为本 App 授予 root 权限。"
    }

    private fun safeWaitFor(p: Process): Int = try {
        p.waitFor()
    } catch (_: InterruptedException) {
        p.destroy()
        -1
    }

    private fun readAll(p: Process, timeoutMs: Long): String {
        val sb = StringBuilder()
        val reader = BufferedReader(InputStreamReader(p.inputStream))
        val endAt = System.currentTimeMillis() + timeoutMs
        val buf = CharArray(1024)
        while (System.currentTimeMillis() < endAt) {
            if (!reader.ready()) {
                try { Thread.sleep(30) } catch (_: InterruptedException) { break }
                continue
            }
            val n = reader.read(buf)
            if (n <= 0) break
            sb.appendRange(buf, 0, n)
            if (sb.length > 4 * 1024 * 1024) break
        }
        return sb.toString().trim()
    }

    private fun readErr(p: Process, timeoutMs: Long): String {
        val sb = StringBuilder()
        val reader = BufferedReader(InputStreamReader(p.errorStream))
        val endAt = System.currentTimeMillis() + timeoutMs
        val buf = CharArray(1024)
        while (System.currentTimeMillis() < endAt) {
            if (!reader.ready()) { try { Thread.sleep(20) } catch (_: InterruptedException) { break }; continue }
            val n = reader.read(buf)
            if (n <= 0) break
            sb.appendRange(buf, 0, n)
            if (sb.length > 32 * 1024) break
        }
        return sb.toString().trim()
    }

    private fun readTextSafe(path: String): String {
        return try { File(path).readText(Charsets.UTF_8) } catch (_: Throwable) { "" }
    }
}

object RootShellConstants {
    const val MIUI_DB_PATH = "/data/data/com.xiaomi.smarthome/databases/miio2.db"
}
