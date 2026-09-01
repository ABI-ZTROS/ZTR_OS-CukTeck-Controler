package com.cuktech.controller

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * RootShell v2 —— 适配 KernelSU 的非阻塞自动夺权桥
 *
 * 核心目标：
 *   App 启动时 3~5 秒内确定 root 是否可用，**绝不阻塞 UI 线程**，
 *   并把 root 管理器（KernelSU / Magisk / 未知）+ 失败原因 + 操作建议
 *   以结构化 JSON 回传给 Dart 层渲染成中文徽章。
 *
 * 🔑 为什么 KernelSU 以前会卡 / 会"提示未找到 root"？
 *   1) 旧代码在主线程 `Runtime.exec().waitFor()` 同步阻塞
 *      → KernelSU 没有"自动响应"时，`su` 一直不退出 → ANR
 *   2) 旧代码没有超时 → 即使用户点了授权，也可能被 su 守护进程拒
 *   3) 旧代码不区分 KSU / Magisk → 提示笼统
 *
 * ⚙️ KernelSU 自动授权建议（给中文 UI 显示）：
 *   打开 KernelSU 管理器 → 「超级用户」 → 找到本 App → 打开
 *   「自动响应」(Auto Response) → 保存。
 *   开了之后再进我们 App，`acquireRoot()` 会秒级返回 uid=0。
 */
class RootShell {

    companion object {
        private const val TAG = "RootShell"

        /** 常见 su 路径（KernelSU / Magisk / SuperSU） */
        private val SU_CANDIDATES = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/debug_ramdisk/su",
            "/data/adb/ksu/bin/su",       // KernelSU >= 0.9.5
            "/data/adb/magisk/magisk64",   // Magisk 安装位
            "/data/adb/ksud",              // KernelSU 守护进程（检测用）
        )

        /** 命令白名单 — 仅允许这些前缀 */
        private val ALLOWED_PREFIXES = listOf(
            "sqlite3 ", "id", "cp ", "chmod ", "cat ", "ls -la ", "ls ",
            "echo ", "rm ", "base64", "od -A", "od ", "stat ",
        )
    }

    // =================== 类型定义 ===================

    enum class RootManager(val key: String, val displayCn: String) {
        KERNEL_SU("kernelsu", "KernelSU"),
        MAGISK("magisk", "Magisk"),
        APATCH("apatch", "APatch"),
        UNKNOWN("unknown", "未知 su 管理器"),
        NONE("none", "未检测到 root 环境"),
    }

    data class ProbeResult(
        val ok: Boolean,              // true = uid=0, 已获得 root
        val manager: RootManager,
        val suVersionText: String,    // su -V / uname 的原始输出
        val uid: Int?,                // 若成功 = 0
        val timeoutMs: Long,          // 本次探测超时阈值
        val suggestion: String,       // 给用户的中文建议
        val rawError: String? = null, // 异常文本
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
            return j
        }

        // — 与 Dart RootState 枚举对齐 —
        private fun stateKey(): String = when {
            ok -> "available"
            timeoutMs == -1L && rawError == null && manager == RootManager.NONE -> "none"
            manager != RootManager.NONE && !ok -> "denied"
            rawError?.contains("TIMEOUT") == true -> "timeout"
            rawError != null -> "error"
            else -> "denied"
        }
    }

    // =================== 管理层探测（Node 级 + 版本级） ===================

    /** 检查物理上是否存在 KernelSU/Magisk/APatch 的痕迹 */
    fun detectRootManager(pair: Pair<String, String>? = null): RootManager {
        // 1. 检查路径（最可靠）
        val candidatesHit = SU_CANDIDATES.filter { File(it).exists() }
        val hasKsuNode = candidatesHit.any {
            it.contains("ksu") || it == "/debug_ramdisk/su"
        } || File("/data/adb/ksud").exists() || File("/data/adb/modules").exists() &&
                !File("/data/adb/magisk").exists() &&
                File("/proc/version").existsSafely() &&
                readTextSafely("/proc/version").contains("kernelsu", true)
        if (hasKsuNode) return RootManager.KERNEL_SU

        if (File("/data/adb/magisk").exists() ||
            candidatesHit.any { it.contains("magisk") }) {
            return RootManager.MAGISK
        }
        if (File("/data/adb/apd").exists() ||
            candidatesHit.any { it.contains("apatch") }) {
            return RootManager.APATCH
        }

        // 2. su -V 版本输出
        val versionText = pair ?: probeSuVersion()
        val v = versionText.second.lowercase()
        return when {
            v.contains("kernelsu") || v.contains(" ksu-") || v.contains("ksu version")
                -> RootManager.KERNEL_SU
            v.contains("magisk") -> RootManager.MAGISK
            v.contains("apatch") -> RootManager.APATCH
            v.isNotBlank() -> RootManager.UNKNOWN
            else -> RootManager.NONE
        }
    }

    private fun probeSuVersion(): Pair<String, String> {
        // 尝试不同参数：KernelSU su 支持 -V、--version；Magisk 常用 -v
        val attempts = listOf(
            arrayOf("su", "-V"),
            arrayOf("su", "--version"),
            arrayOf("su", "-v"),
        )
        for (args in attempts) {
            try {
                val p = Runtime.getRuntime().exec(args)
                val got = readAll(p, 800L).trim()
                if (got.isNotBlank()) return Pair(args.joinToString(" "), got)
            } catch (_: Throwable) {}
        }
        return Pair("", "")
    }

    // =================== 核心：非阻塞夺权 + 超时 ===================

    suspend fun probeRoot(timeoutMs: Long = 5000L): ProbeResult =
        withContext(Dispatchers.IO) {
            val manager = detectRootManager()
            val versionText = probeSuVersion().let { "${it.first} => ${it.second}" }

            if (manager == RootManager.NONE) {
                return@withContext ProbeResult(
                    ok = false,
                    manager = RootManager.NONE,
                    suVersionText = versionText,
                    uid = null,
                    timeoutMs = timeoutMs,
                    suggestion = "设备上未检测到 KernelSU / Magisk / APatch。" +
                            "请先刷入 KernelSU 再回来（推荐 KernelSU ≥ 0.9.5，支持 su -V）。",
                )
            }

            // 3 次尝试避免 su 守护进程首次启动的抖动
            var lastErr: String? = null
            var uidGot: Int? = null
            repeat(3) { attempt ->
                val outcome = withTimeoutOrNull(timeoutMs) {
                    tryRunSuId(timeoutMs, attempt)
                }
                when (outcome) {
                    null -> {
                        // 超时 = KernelSU 弹了授权框但用户没点
                        return@withContext ProbeResult(
                            ok = false,
                            manager = manager,
                            suVersionText = versionText,
                            uid = null,
                            timeoutMs = timeoutMs,
                            suggestion = buildSuggestionTimeout(manager),
                            rawError = "TIMEOUT: su -c id 未在 ${timeoutMs}ms 内返回 " +
                                    "(尝试${attempt + 1}/3) — 通常意味着授权框等待用户点击。",
                        )
                    }
                    is SuRunOutcome.Success -> {
                        uidGot = outcome.uid
                        return@withContext ProbeResult(
                            ok = true,
                            manager = manager,
                            suVersionText = versionText,
                            uid = 0,
                            timeoutMs = timeoutMs,
                            suggestion = buildSuggestionSuccess(manager),
                        )
                    }
                    is SuRunOutcome.Fail -> {
                        lastErr = outcome.msg
                        // 退避 200ms 再重试（KSU 冷启动守护进程会有一个短暂拒绝期）
                        delay(200L)
                    }
                }
            }

            ProbeResult(
                ok = false,
                manager = manager,
                suVersionText = versionText,
                uid = uidGot,
                timeoutMs = timeoutMs,
                suggestion = buildSuggestionDenied(manager),
                rawError = lastErr,
            )
        }

    // =================== 执行 ===================

    private sealed class SuRunOutcome {
        data class Success(val uid: Int) : SuRunOutcome()
        data class Fail(val msg: String) : SuRunOutcome()
    }

    /** 真正执行 su -c id 并解析 uid（不做超时，由上层 withTimeoutOrNull 控） */
    private suspend fun tryRunSuId(overallTimeout: Long, attempt: Int): SuRunOutcome {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            // 用短一点的单项等待，给外层 timeout 兜底
            val stdout = readAll(p, overallTimeout - 200L)
            val stderr = readErr(p, 300L)
            val exit = safeWaitFor(p)
            val uid = "uid=([0-9]+)".toRegex().find(stdout)?.groupValues?.get(1)?.toIntOrNull()
            if (exit == 0 && uid == 0) {
                SuRunOutcome.Success(0)
            } else {
                SuRunOutcome.Fail("exit=$exit uid=$uid stdout=\"$stdout\" stderr=\"$stderr\" att=$attempt")
            }
        } catch (t: Throwable) {
            SuRunOutcome.Fail("EXCEPTION: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** 老派 su 执行（用于 runCommand/readMiotDb，后台线程仍需要超时保护） */
    suspend fun runCommandSuspend(command: String, timeoutMs: Long = 8000L): String {
        assertAllowed(command)
        return withContext(Dispatchers.IO) {
            val outcome = withTimeoutOrNull(timeoutMs) {
                try {
                    val p = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
                    val stdout = readAll(p, timeoutMs - 500L)
                    val stderr = readErr(p, 300L)
                    val exit = safeWaitFor(p)
                    if (exit == 0) stdout else "ERROR($exit): $stderr | stdout=$stdout"
                } catch (t: Throwable) {
                    "EXCEPTION: ${t.javaClass.simpleName}: ${t.message}"
                }
            }
            outcome ?: "TIMEOUT(${timeoutMs}ms): $command"
        }
    }

    fun readMiotDb(dbPath: String, timeoutMs: Long = 12000L): kotlinx.coroutines.Deferred<String> {
        val escaped = dbPath.replace("\"", "\\\"").replace("\'", "\\\'")
        val cmd = "cat \"$escaped\" | base64"
        assertAllowed(cmd)
        return kotlinx.coroutines.GlobalScope.async(Dispatchers.IO) {
            val outcome = withTimeoutOrNull(timeoutMs) {
                try {
                    val p = Runtime.getRuntime().exec(arrayOf("su", "-c", cmd))
                    val out = readAll(p, timeoutMs - 1000L)
                    val exit = safeWaitFor(p)
                    if (exit == 0) out else "ERROR(exit=$exit): $out"
                } catch (t: Throwable) {
                    "EXCEPTION: ${t.javaClass.simpleName}: ${t.message}"
                }
            }
            outcome ?: "TIMEOUT(${timeoutMs}ms): readMiotDb"
        }
    }

    // —————— 兼容老同步 API（仅向后兼容，不要在新代码里调用） ——————
    fun checkRoot(): Boolean {
        Log.w(TAG, "checkRoot(): blocking legacy call; please migrate to probeRoot()")
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val stdout = readAll(p, 3000L)
            safeWaitFor(p)
            stdout.contains("uid=0")
        } catch (_: Throwable) {
            false
        }
    }
    fun runCommand(command: String): String {
        assertAllowed(command)
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
            val stdout = readAll(p, 5000L)
            val stderr = readErr(p, 500L)
            val exit = safeWaitFor(p)
            if (exit == 0) stdout else "ERROR: $stderr"
        } catch (e: SecurityException) { throw e }
        catch (t: Throwable) { "EXCEPTION: ${t.message}" }
    }

    // =================== 工具 ===================

    private fun assertAllowed(cmd: String) {
        val c = cmd.trim()
        if (ALLOWED_PREFIXES.none { prefix -> c.startsWith(prefix) }) {
            throw SecurityException("命令不在白名单: $c")
        }
    }

    private fun buildSuggestionSuccess(m: RootManager): String = when (m) {
        RootManager.KERNEL_SU -> "✅ 已通过 KernelSU 获得 root（uid=0），" +
                "可读取米家数据库。若后续升级 KSU 后失效，请重新打开" +
                "KernelSU 管理器 → 超级用户 → 酷态科控制器 → 保存。"
        RootManager.MAGISK -> "✅ 已通过 Magisk 获得 root（uid=0），可读取米家数据库。"
        RootManager.APATCH -> "✅ 已通过 APatch 获得 root（uid=0），可读取米家数据库。"
        else -> "✅ root 可用。"
    }

    private fun buildSuggestionTimeout(m: RootManager): String = when (m) {
        RootManager.KERNEL_SU -> "⏳ KernelSU 等待授权超时。请依次操作：\n" +
                "  ① 打开 KernelSU 管理器\n" +
                "  ② 点击「超级用户」标签\n" +
                "  ③ 找到「酷态科控制器」并点击进入\n" +
                "  ④ 打开「自动响应」开关（自动授予 / 自动响应）\n" +
                "  ⑤ 回到本 App，点击 Root 徽章「重试」。\n" +
                "  完成后将在 1~2 秒内自动夺权成功。"
        RootManager.MAGISK -> "⏳ Magisk 等待授权超时。请在 Magisk 的授权弹窗里点击「允许」，" +
                "或在 Magisk → 超级用户里为本 App 选择「已授予」。"
        RootManager.APATCH -> "⏳ APatch 等待授权超时。请在 APatch 授权弹窗里点击「允许」。"
        else -> "⏳ root 授权超时。请检查你的 root 管理器是否为该 App 授予了权限。"
    }

    private fun buildSuggestionDenied(m: RootManager): String = when (m) {
        RootManager.KERNEL_SU -> "❌ KernelSU 拒绝了本 App 的 su 请求（exit≠0 / uid≠0）。\n" +
                "请打开 KernelSU 管理器 → 超级用户 → 酷态科控制器 → 确认「自动响应=授予」，" +
                "而不是「拒绝」或「询问」。改完点击 Root 徽章「重试」。"
        RootManager.MAGISK -> "❌ Magisk 拒绝了 su 请求。请在 Magisk → 超级用户中改为「已授予」。"
        RootManager.APATCH -> "❌ APatch 拒绝了 su 请求。请在 APatch 中授权本 App。"
        else -> "❌ su 执行失败。root 管理器授权了，但执行 `su -c id` 没有返回 uid=0。" +
                "请重启手机后重试；如果是系统级 SELinux 拦截，可在 KSU/Magisk 安装模块侧尝试。"
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
            if (sb.length > 4 * 1024 * 1024) break // 最多读 4MB
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

    private fun File.existsSafely(): Boolean = try { exists() } catch (_: Throwable) { false }
    private fun readTextSafely(path: String): String {
        return try { File(path).readText(Charsets.UTF_8) } catch (_: Throwable) { "" }
    }
}

/** 老 API 兼容常量 */
object RootShellConstants {
    const val MIUI_DB_PATH = "/data/data/com.xiaomi.smarthome/databases/miio2.db"
}
