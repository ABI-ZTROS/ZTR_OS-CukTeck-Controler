import 'dart:async';
import '../logger/logger.dart';

/// 通用带重试执行器（最多 3 次，每次 5s timeout）
///
/// [tag] 日志标签
/// [operation] 描述操作名
/// [execute] 实际操作（返回 Future<T>）
/// [onError] 自定义错误判定（返回 true 则立即终止重试）
Future<T> withRetry<T>(
  String tag,
  String operation,
  Future<T> Function() execute, {
  int maxRetries = 3,
  Duration timeout = const Duration(seconds: 5),
  bool Function(Object)? onError,
}) async {
  Object? lastError;
  for (int attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      AppLogger.instance.d(tag, '$operation attempt=$attempt/$maxRetries');
      final result = await execute().timeout(timeout);
      if (attempt > 1) AppLogger.instance.i(tag, '$operation succeeded on attempt $attempt');
      return result;
    } on TimeoutException catch (e) {
      lastError = e;
      AppLogger.instance.w(tag, '$operation timeout (attempt $attempt)', e);
      if (attempt < maxRetries) await Future.delayed(Duration(milliseconds: 200 * attempt));
    } catch (e, st) {
      lastError = e;
      AppLogger.instance.e(tag, '$operation failed (attempt $attempt)', e, st);
      if (onError?.call(e) == true || attempt >= maxRetries) break;
      await Future.delayed(Duration(milliseconds: 200 * attempt));
    }
  }
  throw StateError('$operation failed after $maxRetries attempts: $lastError');
}