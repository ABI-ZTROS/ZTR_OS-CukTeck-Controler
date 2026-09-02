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
import java.io.OutputStream
import java.io.InputStreamReader
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * RootShell v5 —— 为 root 而生的执行流程
 *
 * ──────────────────────────────────────────────────────────────
 * 核心架构：
 *
 *   ┌─ 交互式 Shell（默认路径）────────────────────────────┐
 *   │  1. 启动阶段探测 4 个 su 入口，找到能进入交互式 shell 的
 *   │  2. 启动 su 进程（不带 -c），保持 stdin/stdout 长连接
 *   │  3. 所有命令通过管道写入，带唯一 __END_MARKER__ 分隔
 *   │  4. 读 stdout 直到 marker，一次 read 就是一条命令的结果
 *   │  5. 进程存活期间 = 零进程创建开销 = 最快
 *   └───────────────────────────────────────────────────────┘
 *
 *   ┌─ 降级：批处理 Mode（兜底路径）───────────────────────┐
 *   │  交互式 shell 启动失败时，自动 fallback 到 su -c 模式
 *   │  多条命令自动打包成一次 su -c "cmd1 && cmd2 && cmd3"
 *   └───────────────────────────────────────────────────────┘
 *
 * 特性：
 *   ✅ 一次性授权，后续命令静默执行无弹窗
 *   ✅ 沉默模式 —— 默认无日志，只有失败才输出
 *   ✅ 自动重连 —— shell 死了静默重建，调用方无感
 *   ✅ 探测 = 启动 —— probeRoot 成功后交互式 shell 已活
 *   ✅ 批处理 —— execBatch(vararg) 多条命令一次管道写入
 *   ✅ 对 Dart 端零改动 —— ProbeResult/runCommandSuspend 签名不变
 *
 * KernelSU 适配要点：
 *   KernelSU 通过内核 execve hook 把任何 su 调用重定向到 ksud。
 *   所以 /data/adb/ksu/bin/su、/system/bin/su、PATH 中的 su
 *   最终都走 ksud 的 su.rs → root_shell()。
 *   ksud debug su 是最后才用的兜底，因为 ksud 本身不是 shell。
 * ──────────────────────────────────────────────────────────────
 */
class RootShell {

    companion object {
        private const val TAG = "RootShell"
        private const val DEBUG = false  // 默认沉默，关掉日常日志

        // ── 交互式 shell 探测顺序（不带 -c，期望进入 root shell）──
        private val INTERACTIVE_ENTRIES = listOf<SuEntry>(
            // ① KernelSU >= 0.9.5 专用 su 二进制
            SuEntry("KSU su-bin", "/data/adb/ksu/bin/su", listOf("/data/adb/ksu/bin/su")),
            // ② KernelSU sucompat 或 Magisk 的 /system/bin/su（内核 hook 接管）
            SuEntry("system/bin/su", "/system/bin/su", listOf("/system/bin/su")),
            // ③ PATH 中的 su（内核 hook 同样接管）
            SuEntry("PATH su", "su", listOf("su")),
            // ④ 最后才用 ksud debug su（兜底，ksud 本身不是传统 shell）
            SuEntry("ksud debug su", "/data/adb/ksud", listOf("/data/adb/ksud", "debug", "su")),
        )

        // ── 批处理 fallback（su -c "cmd"）──
        private val BATCH_ENTRIES = listOf<SuEntry>(
            SuEntry("KSU su-bin -c", "/data/adb/ksu/bin/su", null),
            SuEntry("system/bin/su -c", "/system/bin/su", null),
            SuEntry("PATH su -c", "su", null),
            SuEntry("ksud debug su -c", "/data/adb/ksud", null),
        )

        private val ALLOWED_PREFIXES = listOf(
            "sqlite3 ", "id", "cp ", "chmod ", "cat ", "ls -la ", "ls ",
            "echo ", "rm ", "base64", "od -A", "od ", "stat ", "ksud ",
            "test -e", "mkdir ", "touch ",
        )
    }

    // =================== 类型定义 ===================

    private data class SuEntry(
        val name: String,
        val executable: String,
        /** 交互式启动 argv；null 表示这个入口不支持交互式启动，只用 -c 模式 */
        val interactiveArgv: List<String>?,
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

    // =================== 运行时状态 ===================

    private var interactiveShell: InteractiveShell? = null
    private val batchCacheKey = "batch"
    private val workingBatchEntry = ConcurrentHashMap<String, SuEntry>()

    /** 当前 su 入口是否物理存在 */
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

    // =================== 管理层探测 ===================

    fun detectRootManager(): RootManager {
        // 1. KernelSU 专属
        if (File("/data/adb/ksud").exists()) return RootManager.KERNEL_SU
        if (readTextSafe("/proc/version").contains("kernelsu", ignoreCase = true))
            return RootManager.KERNEL_SU
        if (File("/data/adb/ksu/bin/su").exists()) return RootManager.KERNEL_SU

        // 2. Magisk
        if (File("/data/adb/magisk").exists()) return RootManager.MAGISK

        // 3. APatch
        if (File("/data/adb/apd").exists() || File("/data/adb/apatch").exists())
            return RootManager.APATCH

        // 4. 版本号文本
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
        for (entry in BATCH_ENTRIES) {
            if (!isEntryAvailable(entry)) continue
            for (flag in arrayOf("-V", "--version", "-v")) {
                try {
                    val argv = batchArgv(entry, "echo __V__; ${entry.executable} $flag")
                    val p = Runtime.getRuntime().exec(argv)
                    val got = readAll(p, 800L).trim()
                    if (got.isNotBlank()) {
                        // 过滤掉我们自己的 marker
                        val lines = got.lines().filter { !it.startsWith("__V__") }
                        if (lines.isNotEmpty()) return lines.joinToString("\n")
                    }
                } catch (_: Throwable) {}
            }
        }
        return ""
    }

    private fun batchArgv(entry: SuEntry, cmd: String): Array<String> {
        return when (entry.executable) {
            "/data/adb/ksud" -> arrayOf("/data/adb/ksud", "debug", "su", "-c", cmd)
            else -> arrayOf(entry.executable, "-c", cmd)
        }
    }

    // =================== 核心：探测 + 启动交互式 shell ===================

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

            if (DEBUG) Log.i(TAG, "检测到 ${manager.displayCn}，开始探测 su 入口…")

            val details = mutableListOf<SuProbeOutcome>()
            var lastErr: String? = null

            // ① 先尝试交互式 shell（最快，一次启动终身复用）
            for (entry in INTERACTIVE_ENTRIES) {
                if (!isEntryAvailable(entry)) {
                    details.add(SuProbeOutcome(entry.name, false, null, null, "not available"))
                    continue
                }
                if (entry.interactiveArgv == null) {
                    details.add(SuProbeOutcome(entry.name, true, null, null, "entry has no interactive mode"))
                    continue
                }

                val shell = InteractiveShell.tryOpen(entry, timeoutMs)
                if (shell != null) {
                    val uid = shell.probeUid()
                    if (uid == 0) {
                        interactiveShell = shell
                        if (DEBUG) Log.i(TAG, "✅ 交互式 shell 已启动 via ${entry.name}, uid=0")
                        details.add(SuProbeOutcome(entry.name, true, 0, 0, null))
                        return@withContext ProbeResult(
                            ok = true, manager = manager,
                            suVersionText = suVer, uid = 0,
                            timeoutMs = timeoutMs,
                            suggestion = buildSuccessSuggestion(manager, entry.name, interactive = true),
                            detectionMethod = "interactive:${entry.name}",
                            probeDetails = details,
                        )
                    } else {
                        details.add(SuProbeOutcome(entry.name, true, uid, 0, "uid=$uid not root"))
                    }
                } else {
                    details.add(SuProbeOutcome(entry.name, true, null, null, "interactive open failed"))
                }
            }

            // ② 降级：批处理模式探测
            for (entry in BATCH_ENTRIES) {
                if (!isEntryAvailable(entry)) {
                    details.add(SuProbeOutcome(entry.name, false, null, null, "not available"))
                    continue
                }

                val res = withTimeoutOrNull(timeoutMs) {
                    executeBatchRaw(entry, "id", timeoutMs)
                }

                if (res == null) {
                    details.add(SuProbeOutcome(entry.name, true, null, null,
                        "TIMEOUT ${timeoutMs}ms — 授权弹窗未确认?"))
                    lastErr = "TIMEOUT: ${entry.name}"
                    continue
                }

                details.add(SuProbeOutcome(entry.name, true, res.uid, res.exit, res.errorMsg))

                if (res.exit == 0 && res.uid == 0) {
                    workingBatchEntry[batchCacheKey] = entry
                    if (DEBUG) Log.i(TAG, "✅ 批处理模式可用 via ${entry.name}")
                    return@withContext ProbeResult(
                        ok = true, manager = manager,
                        suVersionText = suVer, uid = 0,
                        timeoutMs = timeoutMs,
                        suggestion = buildSuccessSuggestion(manager, entry.name, interactive = false),
                        detectionMethod = "batch:${entry.name}",
                        probeDetails = details,
                    )
                }

                lastErr = "[${entry.name}] exit=${res.exit} uid=${res.uid} err=${res.errorMsg?.take(100)}"
            }

            if (DEBUG) Log.w(TAG, "所有入口均失败")
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

    suspend fun runCommandSuspend(command: String, timeoutMs: Long = 8000L): String {
        assertAllowed(command)
        return withContext(Dispatchers.IO) {
            // 优先走交互式 shell
            val shell = interactiveShell
            if (shell != null && shell.isAlive()) {
                val r = shell.exec(command, timeoutMs)
                if (r.error == null) return@withContext r.output
                // 交互式 shell 可能挂了，静默重连一次
                interactiveShell = null
                // 重连
                for (entry in INTERACTIVE_ENTRIES) {
                    if (entry.interactiveArgv == null || !isEntryAvailable(entry)) continue
                    val newShell = InteractiveShell.tryOpen(entry, timeoutMs)
                    if (newShell != null && newShell.probeUid() == 0) {
                        interactiveShell = newShell
                        val r2 = newShell.exec(command, timeoutMs)
                        return@withContext r2.output.ifBlank { "ROOT_FAIL: ${r2.error}" }
                    }
                }
            }

            // 降级：批处理模式
            for (entry in listOfNotNull(workingBatchEntry[batchCacheKey]) + BATCH_ENTRIES) {
                if (!isEntryAvailable(entry)) continue
                val r = executeBatchRaw(entry, command, timeoutMs)
                if (r.exit == 0) {
                    workingBatchEntry[batchCacheKey] = entry
                    return@withContext r.stdout.ifBlank { r.stderr }
                }
            }
            "ROOT_FAIL: all su entries failed for '${command.take(40)}'"
        }
    }

    /** 批量执行多条命令 —— 交互式 shell 下一次管道写入，批处理下一次进程创建 */
    suspend fun execBatch(vararg commands: String, timeoutMs: Long = 15000L): List<String> {
        return withContext(Dispatchers.IO) {
            val shell = interactiveShell
            if (shell != null && shell.isAlive()) {
                return@withContext shell.execBatch(commands.toList(), timeoutMs).map { it.output }
            }
            // 降级：批处理下也打包执行（用 && 连接，返回最后一条的输出分开比较难，简单点每条跑一次）
            commands.map { cmd -> runCommandSuspend(cmd, timeoutMs) }
        }
    }

    /** 读取米家数据库（异步 Deferred）—— 直接走持久化 shell */
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

    // =================== 批处理底层 ===================

    private data class RawResult(
        val stdout: String,
        val stderr: String,
        val exit: Int,
        val uid: Int?,
        val errorMsg: String?,
    )

    private fun executeBatchRaw(entry: SuEntry, cmd: String, timeoutMs: Long): RawResult {
        return try {
            val p = Runtime.getRuntime().exec(batchArgv(entry, cmd))
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
            RawResult("", "", -1, null,
                "EXCEPTION: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // =================== 交互式 Shell 实现 ===================

    /**
     * 持久化的交互式 root shell。
     * 一次启动，通过 stdin 管道写入命令，stdout 带 marker 分隔结果。
     *
     * 命令格式：
     *   (cmd1); (cmd2); echo EXITCODE=$?; echo __END_N_MARKER__
     *
     * 我们读 stdout，直到看到 marker，marker 前最后一行是 EXITCODE，前面是输出。
     */
    private class InteractiveShell private constructor(
        private val entryName: String,
        private val process: Process,
        private val stdin: OutputStream,
        private val stdout: BufferedReader,
    ) {
        private val lock = Any()

        data class ExecResult(val output: String, val exitCode: Int, val error: String?)

        fun isAlive(): Boolean {
            if (!process.isAlive) return false
            try { stdin.flush() } catch (_: Throwable) { return false }
            return true
        }

        fun probeUid(): Int? {
            val r = exec("id", 3000L)
            if (r.error != null) return null
            return "uid=([0-9]+)".toRegex().find(r.output)?.groupValues?.get(1)?.toIntOrNull()
        }

        fun exec(cmd: String, timeoutMs: Long): ExecResult {
            return synchronized(lock) {
                try {
                    val marker = endMarker()
                    val wrapper = "($cmd); echo __EXIT__=\$?; echo $marker\n"
                    stdin.write(wrapper.toByteArray(Charsets.UTF_8))
                    stdin.flush()
                    val raw = readUntilMarker(marker, timeoutMs)
                    parseExecResult(raw)
                } catch (t: Throwable) {
                    ExecResult("", -1, "SHELL_DEAD: ${t.message}")
                }
            }
        }

        fun execBatch(cmds: List<String>, timeoutMs: Long): List<ExecResult> {
            return synchronized(lock) {
                try {
                    val marker = endMarker()
                    // 每条命令用分号 + 独立 EXITCODE 行，全部打包一次写入
                    val sb = StringBuilder()
                    cmds.forEachIndexed { i, cmd ->
                        sb.append("($cmd); echo __EXIT_${i}__=\$?\n")
                    }
                    sb.append("echo $marker\n")
                    stdin.write(sb.toString().toByteArray(Charsets.UTF_8))
                    stdin.flush()
                    val raw = readUntilMarker(marker, timeoutMs)
                    parseBatchResult(raw, cmds.size)
                } catch (t: Throwable) {
                    cmds.map { ExecResult("", -1, "BATCH_SHELL_DEAD: ${t.message}") }
                }
            }
        }

        private fun parseExecResult(raw: String): ExecResult {
            val lines = raw.lines().toMutableList()
            // 最后一行应该是 __EXIT__=N
            var exitCode = 0
            val exitLineIdx = lines.indexOfLast { it.startsWith("__EXIT__=") }
            if (exitLineIdx >= 0) {
                exitCode = lines[exitLineIdx].removePrefix("__EXIT__=").toIntOrNull() ?: -1
                lines.removeAt(exitLineIdx)
            }
            val output = lines.joinToString("\n").trim()
            val err = if (exitCode != 0) "exit=$exitCode" else null
            return ExecResult(output, exitCode, err)
        }

        private fun parseBatchResult(raw: String, n: Int): List<ExecResult> {
            val results = MutableList(n) { ExecResult("", 0, null) }
            val lines = raw.lines()
            val exitRe = Regex("^__EXIT_(\\d+)__=(\\d+)$")
            // 先找所有 EXIT 行的位置
            val exitIndices = mutableListOf<Pair<Int, Int>>() // (cmdIdx, lineIdx)
            lines.forEachIndexed { i, line ->
                exitRe.matchEntire(line)?.let { m ->
                    exitIndices.add(m.groupValues[1].toInt() to i)
                }
            }
            // 每条命令的输出 = 上一个 exit 行之后 到 本 exit 行之前
            for (ci in 0 until n) {
                val exitLineIdx = exitIndices.firstOrNull { it.first == ci }?.second ?: continue
                val startIdx = if (ci == 0) 0 else (exitIndices.firstOrNull { it.first == ci - 1 }?.second ?: -1) + 1
                val outputLines = lines.subList(startIdx, exitLineIdx)
                val exitCode = exitRe.matchEntire(lines[exitLineIdx])?.groupValues?.get(2)?.toIntOrNull() ?: -1
                results[ci] = ExecResult(
                    output = outputLines.joinToString("\n").trim(),
                    exitCode = exitCode,
                    error = if (exitCode != 0) "exit=$exitCode" else null,
                )
            }
            return results
        }

        private fun readUntilMarker(marker: String, timeoutMs: Long): String {
            val sb = StringBuilder()
            val endAt = System.currentTimeMillis() + timeoutMs.coerceAtLeast(500)
            val buf = CharArray(2048)
            var totalBytes = 0
            while (System.currentTimeMillis() < endAt && totalBytes < 4 * 1024 * 1024) {
                if (!stdout.ready()) {
                    try { Thread.sleep(15) } catch (_: InterruptedException) { break }
                    continue
                }
                val n = stdout.read(buf)
                if (n <= 0) break
                sb.appendRange(buf, 0, n)
                totalBytes += n
                // 快速检查 marker 是否出现在末尾
                val tailStart = (sb.length - marker.length - 100).coerceAtLeast(0)
                val tail = sb.substring(tailStart)
                if (tail.contains(marker)) {
                    // marker 之前的内容就是结果
                    val markerIdx = sb.indexOf(marker)
                    return sb.substring(0, markerIdx).trim()
                }
            }
            return sb.toString().trim()
        }

        companion object {
            fun tryOpen(entry: SuEntry, timeoutMs: Long): InteractiveShell? {
                val argv = entry.interactiveArgv ?: return null
                return try {
                    val p = ProcessBuilder(*argv.toTypedArray())
                        .redirectErrorStream(true)  // 合并 stderr → stdout，管道统一
                        .start()
                    val stdin = p.outputStream
                    val stdout = BufferedReader(InputStreamReader(p.inputStream))

                    // 探活：发一个 echo marker，确认 shell 正常
                    val marker = endMarker()
                    stdin.write("echo __PROBE_OK__; echo $marker\n".toByteArray(Charsets.UTF_8))
                    stdin.flush()

                    // 等最多 timeoutMs/2 秒
                    val endAt = System.currentTimeMillis() + (timeoutMs / 2).coerceAtLeast(1000)
                    var foundProbe = false
                    val buf = CharArray(2048)
                    val sb = StringBuilder()
                    while (System.currentTimeMillis() < endAt) {
                        if (!stdout.ready()) {
                            Thread.sleep(20)
                            continue
                        }
                        val n = stdout.read(buf)
                        if (n <= 0) break
                        sb.appendRange(buf, 0, n)
                        val s = sb.toString()
                        if (s.contains("__PROBE_OK__") && s.contains(marker)) {
                            foundProbe = true
                            break
                        }
                    }

                    if (foundProbe) {
                        InteractiveShell(entry.name, p, stdin, stdout)
                    } else {
                        p.destroy()
                        null
                    }
                } catch (e: Throwable) {
                    null
                }
            }

            private fun endMarker() = "__END_${System.nanoTime()}_${Random.nextInt(1_000_000)}__"
        }
    }

    // =================== 工具函数 ===================

    private fun assertAllowed(cmd: String) {
        val c = cmd.trim()
        if (ALLOWED_PREFIXES.none { c.startsWith(it) }) {
            throw SecurityException("命令不在白名单: $c")
        }
    }

    private fun buildSuccessSuggestion(m: RootManager, entry: String, interactive: Boolean) = when (m) {
        RootManager.KERNEL_SU -> {
            val mode = if (interactive) "持久化 root shell（零开销模式）" else "批处理模式"
            "✅ 已通过 KernelSU 获得 root —— $mode。" +
                    "建议：KernelSU 管理器 → 超级用户 → 本 App → 自动响应设为「授予」。"
        }
        RootManager.MAGISK -> "✅ 已通过 Magisk 获得 root（uid=0）。"
        RootManager.APATCH -> "✅ 已通过 APatch 获得 root（uid=0）。"
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
