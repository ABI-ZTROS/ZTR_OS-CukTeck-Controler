using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CukTechController.Utils;

/// <summary>
/// 日志等级
/// </summary>
public enum LogLevel { Verbose, Debug, Info, Warning, Error }

/// <summary>
/// 应用日志 —— 单例，支持滚动文件输出 + Debug 输出 + 内存缓冲
/// </summary>
public class AppLogger
{
    private static readonly Lazy<AppLogger> _instance = new();
    public static AppLogger Instance => _instance.Value;

    private readonly List<string> _buffer = new();
    private readonly object _lock = new();
    private LogLevel _level = LogLevel.Debug;
    private string? _logPath;
    private const int _maxBuffer = 1000;
    private const long _maxFileSize = 2 * 1024 * 1024; // 2MB
    private const int _maxFiles = 5;

    /// <summary>
    /// 日志写入事件（供 UI 实时订阅）
    /// </summary>
    public event EventHandler<string>? LogWritten;

    /// <summary>
    /// 当前日志文件路径
    /// </summary>
    public string LogPath { get; private set; } = string.Empty;

    /// <summary>
    /// 配置日志目录与等级
    /// </summary>
    public void Configure(string directory, LogLevel level = LogLevel.Debug)
    {
        _level = level;
        Directory.CreateDirectory(directory);
        LogPath = Path.Combine(directory, "cuktech.log");
        _logPath = LogPath;
    }

    /// <summary>
    /// 设置日志等级
    /// </summary>
    public void SetLevel(LogLevel level) => _level = level;

    /// <summary>
    /// 核心日志方法
    /// </summary>
    public void Log(LogLevel level, string tag, string message, Exception? ex = null)
    {
        if (level < _level) return;
        var ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
        var line = $"{ts} [{level.ToString().ToUpperInvariant().PadRight(7)}] {tag}: {message}";
        if (ex != null) line += $"\n  {ex.GetType().Name}: {ex.Message}\n  {ex}";
        lock (_lock)
        {
            _buffer.Add(line);
            if (_buffer.Count > _maxBuffer)
                _buffer.RemoveRange(0, _buffer.Count - _maxBuffer);
        }
        Debug.WriteLine(line);
        ThreadPool.QueueUserWorkItem(_ => WriteToDisk(line));
        LogWritten?.Invoke(this, line);
    }

    private void WriteToDisk(string line)
    {
        try
        {
            if (string.IsNullOrEmpty(_logPath)) return;
            File.AppendAllText(_logPath, line + Environment.NewLine);
            RolloverIfNeeded();
        }
        catch { /* ignore */ }
    }

    private void RolloverIfNeeded()
    {
        try
        {
            if (string.IsNullOrEmpty(_logPath)) return;
            var info = new FileInfo(_logPath);
            if (info.Length < _maxFileSize) return;
            var rotated = _logPath + ".1";
            if (File.Exists(rotated)) File.Delete(rotated);
            File.Move(_logPath!, rotated);
            for (int i = _maxFiles - 1; i >= 1; i--)
            {
                var prev = $"{rotated}.{i}";
                var next = $"{rotated}.{i + 1}";
                if (File.Exists(prev)) File.Move(prev, next);
            }
        }
        catch { /* ignore */ }
    }

    /// <summary>
    /// 获取内存缓冲日志（只读副本）
    /// </summary>
    public IReadOnlyList<string> GetBuffered()
    {
        lock (_lock) return _buffer.ToList().AsReadOnly();
    }

    // ---- 快捷方法（带 tag 的新 API） ----

    public void V(string tag, string msg) => Log(LogLevel.Verbose, tag, msg);
    public void D(string tag, string msg) => Log(LogLevel.Debug, tag, msg);
    public void I(string tag, string msg) => Log(LogLevel.Info, tag, msg);
    public void W(string tag, string msg, Exception? ex = null) => Log(LogLevel.Warning, tag, msg, ex);
    public void E(string tag, string msg, Exception? ex = null) => Log(LogLevel.Error, tag, msg, ex);

    // ---- 向后兼容方法（旧 API，无 tag） ----

    public void Debug(string message, Exception? ex = null) => D("App", message, ex);
    public void Info(string message, Exception? ex = null) => I("App", message, ex);
    public void Warning(string message, Exception? ex = null) => W("App", message, ex);
    public void Error(string message, Exception? ex = null) => E("App", message, ex);

    // ---- 静态便捷方法（向后兼容） ----

    public static void Debug(string message, Exception? ex = null) => Instance.D("App", message, ex);
    public static void Info(string message, Exception? ex = null) => Instance.I("App", message, ex);
    public static void Warn(string message, Exception? ex = null) => Instance.W("App", message, ex);
    public static void Error(string message, Exception? ex = null) => Instance.E("App", message, ex);
}

/// <summary>
/// 通用带重试执行器：3 次 retry，每次 5s timeout
/// </summary>
public static class RetryHelper
{
    public static async Task<T> WithRetryAsync<T>(
        string tag,
        string operation,
        Func<CancellationToken, Task<T>> execute,
        int maxRetries = 3,
        int timeoutSeconds = 5,
        Func<Exception, bool>? fatal = null)
    {
        Exception? lastError = null;
        for (int attempt = 1; attempt <= maxRetries; attempt++)
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            try
            {
                AppLogger.Instance.D(tag, $"{operation} attempt={attempt}/{maxRetries}");
                var result = await execute(cts.Token);
                if (attempt > 1) AppLogger.Instance.I(tag, $"{operation} succeeded on attempt {attempt}");
                return result;
            }
            catch (OperationCanceledException ex)
            {
                lastError = ex;
                AppLogger.Instance.W(tag, $"{operation} timeout (attempt {attempt})");
                if (attempt < maxRetries) await Task.Delay(200 * attempt);
            }
            catch (Exception ex)
            {
                lastError = ex;
                AppLogger.Instance.E(tag, $"{operation} failed (attempt {attempt})", ex);
                if (fatal?.Invoke(ex) == true || attempt >= maxRetries) break;
                await Task.Delay(200 * attempt);
            }
        }
        throw new InvalidOperationException($"{operation} failed after {maxRetries} attempts", lastError);
    }
}