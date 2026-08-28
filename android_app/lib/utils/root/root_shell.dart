import 'package:flutter/services.dart';
import '../logger/logger.dart';

/// Root Shell —— 通过 MethodChannel 与 Kotlin 层通信执行 su 命令
///
/// 所有命令在 Kotlin 层已白名单化。Dart 侧仅做必要的错误
/// 包装与日志记录，不再重复白名单（避免双端规则不一致）。
class RootShell {
  RootShell._();
  static final RootShell instance = RootShell._();

  static const MethodChannel _channel =
      MethodChannel('com.cuktech.controller/root_shell');

  bool _isRootAvailable = false;

  /// Root 是否可用（最近一次 checkRoot 的缓存结果）
  bool get isRootAvailable => _isRootAvailable;

  /// 检查 Root 权限
  ///
  /// 异步执行 `su -c id` 并验证输出包含 `uid=0`。
  /// 任何异常均视为无 Root。
  Future<bool> checkRoot() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('checkRoot');
      _isRootAvailable = result ?? false;
      AppLogger.instance.i(
        'RootShell',
        'Root check: ${_isRootAvailable ? 'available' : 'not available'}',
      );
      return _isRootAvailable;
    } catch (e, stackTrace) {
      AppLogger.instance.e('RootShell', 'Root check failed: $e', stackTrace);
      _isRootAvailable = false;
      return false;
    }
  }

  /// 执行白名单内的 Root 命令
  ///
  /// [command] 将在 Kotlin 层通过 `su -c <command>` 执行。
  /// 命令必须以 `sqlite3 `、`id`、`cp `、`chmod `、`cat `、`ls -la ` 开头，
  /// 否则 Kotlin 层将抛出 [SecurityException]。
  /// 返回 stdout（含 stderr 前缀 `ERR:`）。
  Future<String> runCommand(String command) async {
    try {
      final String? result = await _channel.invokeMethod<String>(
        'runCommand',
        <String, dynamic>{'command': command},
      );
      AppLogger.instance.d('RootShell', 'runCommand: $command -> $result');
      return result ?? '';
    } on PlatformException catch (e, stackTrace) {
      AppLogger.instance.e(
        'RootShell',
        'runCommand failed: ${e.message} (code=${e.code})',
        stackTrace,
      );
      rethrow;
    } catch (e, stackTrace) {
      AppLogger.instance.e('RootShell', 'runCommand failed: $e', stackTrace);
      rethrow;
    }
  }

  /// 便捷：读取米家 miio2.db 的 devices 表
  ///
  /// [dbPath] 数据库路径，默认米家官方路径
  /// 返回 sqlite3 的原始输出（每行 `did|model|token|mac|name`）
  Future<String> readMiotDb({
    String dbPath = '/data/data/com.xiaomi.smarthome/databases/miio2.db',
  }) async {
    try {
      final String? result = await _channel.invokeMethod<String>(
        'readMiotDb',
        <String, dynamic>{'dbPath': dbPath},
      );
      AppLogger.instance.d(
        'RootShell',
        'readMiotDb($dbPath) -> ${result?.length ?? 0} chars',
      );
      return result ?? '';
    } catch (e, stackTrace) {
      AppLogger.instance.e('RootShell', 'readMiotDb failed: $e', stackTrace);
      rethrow;
    }
  }
}
