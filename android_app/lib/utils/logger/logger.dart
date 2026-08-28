import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 日志等级
enum LogLevel { verbose, debug, info, warning, error }

/// 全局应用日志 —— 单例，支持滚动文件输出 + Logcat 输出
class AppLogger {
  AppLogger._private();
  static final AppLogger instance = AppLogger._private();

  final List<String> _bufferedLogs = [];
  final int _maxBuffer = 500;
  final int _maxFileSizeBytes = 2 * 1024 * 1024; // 2MB rollover
  final int _maxFiles = 5;

  String? _logFilePath;
  LogLevel _level = LogLevel.debug;

  /// 日志文件路径（异步获取，首次调用时创建目录和文件）
  Future<String?> get logPath async {
    if (_logFilePath != null) return _logFilePath;
    try {
      final dir = await getApplicationSupportDirectory();
      _logFilePath = '${dir.path}/cuktech.log';
      final file = File(_logFilePath!);
      if (!await file.exists()) await file.create();
      return _logFilePath;
    } catch (e) {
      stderr.writeln('AppLogger init failed: $e');
      return null;
    }
  }

  /// 设置日志等级
  void setLevel(LogLevel l) => _level = l;

  /// 核心日志方法
  void log(LogLevel level, String tag, String msg,
      [Object? error, StackTrace? stack]) {
    if (level.index < _level.index) return;
    final ts = DateTime.now().toIso8601String();
    final prefix = level.name.toUpperCase().padRight(7);
    final line = '$ts [$prefix] $tag: $msg';
    _bufferedLogs.add(line);
    if (_bufferedLogs.length > _maxBuffer) {
      _bufferedLogs.removeRange(0, _bufferedLogs.length - _maxBuffer);
    }
    // 输出到 Logcat
    debugPrint(line);
    if (error != null) debugPrint('$error\n$stack');
    // 异步写文件（非阻塞）
    _writeToFile(line, error, stack);
  }

  Future<void> _writeToFile(String line, Object? error, StackTrace? stack) async {
    try {
      final path = await logPath;
      if (path == null) return;
      final file = File(path);
      final sink = file.openWrite(mode: FileMode.append);
      sink.writeln(line);
      if (error != null) {
        sink.writeln('  ${error.runtimeType}: $error');
        if (stack != null) sink.writeln('  $stack');
      }
      await sink.flush();
      await sink.close();
      await _rolloverIfNeeded(file);
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _rolloverIfNeeded(File file) async {
    try {
      final stat = await file.stat();
      if (stat.size < _maxFileSizeBytes) return;
      final rotated = '${file.path}.1';
      await file.rename(rotated);
      for (int i = _maxFiles - 1; i >= 1; i--) {
        final prev = '$rotated.$i';
        final next = '$rotated.${i + 1}';
        final f = File(prev);
        if (await f.exists()) await f.rename(next);
      }
    } catch (_) {
      /* ignore */
    }
  }

  /// 获取内存缓冲日志（供 LogPage 等直接读取）
  List<String> getBuffered() => List.unmodifiable(_bufferedLogs);

  void v(String tag, String msg) => log(LogLevel.verbose, tag, msg);
  void d(String tag, String msg) => log(LogLevel.debug, tag, msg);
  void i(String tag, String msg) => log(LogLevel.info, tag, msg);
  void w(String tag, String msg, [Object? error, StackTrace? stack]) =>
      log(LogLevel.warning, tag, msg, error, stack);
  void e(String tag, String msg, [Object? error, StackTrace? stack]) =>
      log(LogLevel.error, tag, msg, error, stack);
}