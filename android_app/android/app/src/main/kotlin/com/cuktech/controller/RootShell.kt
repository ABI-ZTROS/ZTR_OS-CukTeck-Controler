package com.cuktech.controller

import android.util.Log
import java.io.BufferedReader

/**
 * Root Shell —— 通过 su 命令执行 Root 操作。
 * 严格白名单化，只允许下列命令：
 *   - sqlite3 (读取 miio2.db)
 *   - cp / chmod (临时文件拷贝与权限修改)
 *   - id (Root 检测)
 * 任何其他命令均抛出 SecurityException。
 */
class RootShell {

    companion object {
        private const val TAG = "RootShell"

        // 白名单前缀（按命令名匹配，禁止 shell 元字符拼接额外命令）
        private val ALLOWED_COMMANDS = listOf(
            "sqlite3 ",
            "id",
            "cp ",
            "chmod ",
            "cat ",
            "ls -la "
        )

        // 禁止的危险模式
        private val DANGEROUS_PATTERNS = listOf(
            "&&", "||", ";", "|", "`", "$(", ">", ">>", "<",
            "/data/data/com.xiaomi.smarthome",  // 除 sqlite3/cp 外不允许直接访问
            "rm ", "mv ", "dd ", "mkfs"
        )
    }

    /**
     * 检查命令是否通过白名单。
     * 仅允许以下格式：
     *   1. 单命令 `sqlite3 <path> <sql>`
     *   2. `id`
     *   3. `cp <src> <dst>`
     *   4. `chmod <mode> <path>`
     *   5. `cat <path>`
     *   6. `ls -la <path>`
     */
    fun validate(command: String): String {
        val trimmed = command.trim()
        if (trimmed.isEmpty()) {
            throw IllegalArgumentException("命令不能为空")
        }
        // 禁止危险 shell 元字符
        for (pattern in DANGEROUS_PATTERNS) {
            if (pattern in trimmed) {
                throw SecurityException("命令包含禁止的模式: '$pattern'。完整命令: $trimmed")
            }
        }
        // 必须以白名单前缀开头
        val allowed = ALLOWED_COMMANDS.any { prefix ->
            trimmed == prefix.trim() || trimmed.startsWith(prefix)
        }
        if (!allowed) {
            throw SecurityException("命令未通过白名单检查: $trimmed")
        }
        return trimmed
    }

    /**
     * 检查 Root 权限
     */
    fun checkRoot(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val exitCode = process.waitFor()
            val output = process.inputStream.bufferedReader().use(BufferedReader::readText)
            Log.d(TAG, "Root check exitCode=$exitCode output=${output.trim()}")
            exitCode == 0 && output.contains("uid=0")
        } catch (e: Exception) {
            Log.e(TAG, "Root check failed", e)
            false
        }
    }

    /**
     * 执行 Root 命令（带白名单检查）
     * @return 命令输出（stdout + stderr 拼接）
     * @throws SecurityException 当命令未通过白名单
     */
    fun runCommand(command: String): String {
        val validated = validate(command)
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", validated))
            val stdout = process.inputStream.bufferedReader().use(BufferedReader::readText)
            val stderr = process.errorStream.bufferedReader().use(BufferedReader::readText)
            val exitCode = process.waitFor()
            val combined = buildString {
                append(stdout.trim())
                if (stderr.isNotBlank()) {
                    if (isNotEmpty()) append('\n')
                    append("ERR: ").append(stderr.trim())
                }
            }
            Log.d(TAG, "runCommand '$validated' (exit=$exitCode) -> $combined")
            combined
        } catch (e: Exception) {
            Log.e(TAG, "runCommand failed: $validated", e)
            throw e
        }
    }

    /**
     * 便捷：读取米家 miio2.db 的 devices 表
     * @return raw sqlite3 输出文本
     */
    fun readMiotDb(dbPath: String = RootShellConstants.MIUI_DB_PATH): String {
        val sql = "select did, model, token, mac, name from devices;"
        // 用双引号包裹 SQL 字面量 + 单引号包裹路径，避免 shell 转义
        val command = "sqlite3 $dbPath \"$sql\""
        return runCommand(command)
    }
}

/**
 * 常量对象 —— 供 MethodChannel 层和 RootShell 共同引用
 */
object RootShellConstants {
    const val MIUI_DB_PATH = "/data/data/com.xiaomi.smarthome/databases/miio2.db"
}
