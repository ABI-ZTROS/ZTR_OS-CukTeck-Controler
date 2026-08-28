package com.cuktech.controller

import android.util.Log
import java.io.BufferedReader
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStreamReader

/**
 * Root Shell 工具类：通过 su 执行命令
 * 要求设备已 root 且已授权 su
 */
class RootShell {

    companion object {
        private const val TAG = "RootShell"
    }

    /** 检查是否有 root 权限 */
    fun checkRoot(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val exitCode = process.waitFor()
            val output = process.inputStream.bufferedReader().readText().trim()
            exitCode == 0 && output.contains("uid=0")
        } catch (e: Exception) {
            Log.e(TAG, "checkRoot failed", e)
            false
        }
    }

    /** 执行 root 命令 */
    fun runCommand(command: String): String {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
            val stdout = process.inputStream.bufferedReader().readText().trim()
            val stderr = process.errorStream.bufferedReader().readText().trim()
            val exitCode = process.waitFor()
            if (exitCode == 0) stdout else "ERROR: $stderr"
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "runCommand failed: $command", e)
            "EXCEPTION: ${e.message}"
        }
    }

    /** 读取 miio2.db 数据库文件 */
    fun readMiotDb(dbPath: String): String {
        return try {
            val escapedPath = dbPath.replace("\"", "\\\"")
            val command = "cat \"$escapedPath\" | base64"
            runCommand(command)
        } catch (e: Exception) {
            Log.e(TAG, "readMiotDb failed", e)
            throw e
        }
    }
}

/**
 * Root Shell 常量
 */
object RootShellConstants {
    const val MIUI_DB_PATH = "/data/data/com.xiaomi.smarthome/databases/miio2.db"
}
