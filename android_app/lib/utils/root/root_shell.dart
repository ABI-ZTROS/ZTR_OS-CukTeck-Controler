import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../logger/logger.dart';

/// Root 状态（与 Kotlin ProbeResult.stateKey 对齐）
enum RootState {
  /// 首次启动还没开始探测
  unknown,

  /// 探测中
  checking,

  /// 成功：uid=0
  available,

  /// 设备上根本没装 KernelSU / Magisk / APatch
  none,

  /// 有 root 管理器，但 su 请求被拒绝（uid≠0 / exit≠0）
  denied,

  /// 有 root 管理器，但 su -c id 在超时（一般 5s）内没返回 → 通常
  /// 是 KernelSU 弹了授权框但用户没点
  timeout,

  /// 出现异常
  error,
}

/// Root 管理器类型（与 Kotlin RootManager.key 对齐）
enum RootManager {
  kernelsu,
  magisk,
  apatch,
  unknown,
  none;

  static RootManager parse(String? s) {
    switch (s?.toLowerCase()) {
      case 'kernelsu':
        return RootManager.kernelsu;
      case 'magisk':
        return RootManager.magisk;
      case 'apatch':
        return RootManager.apatch;
      case 'unknown':
        return RootManager.unknown;
      case 'none':
        return RootManager.none;
      default:
        return RootManager.unknown;
    }
  }

  String get displayName {
    switch (this) {
      case RootManager.kernelsu:
        return 'KernelSU';
      case RootManager.magisk:
        return 'Magisk';
      case RootManager.apatch:
        return 'APatch';
      case RootManager.unknown:
        return '未知管理器';
      case RootManager.none:
        return '无';
    }
  }
}

/// 一次探测的结构化结果
class RootStatus {
  const RootStatus({
    required this.state,
    required this.manager,
    required this.managerDisplay,
    this.suggestion,
    this.suVersion,
    this.uid,
    this.timeoutMs,
    this.rawError,
  });

  final RootState state;
  final RootManager manager;
  final String managerDisplay;
  final String? suggestion;
  final String? suVersion;
  final int? uid;
  final int? timeoutMs;
  final String? rawError;

  bool get isOk => state == RootState.available;

  factory RootStatus.unknown() => const RootStatus(
        state: RootState.unknown,
        manager: RootManager.none,
        managerDisplay: '未检测',
      );
  factory RootStatus.checking() => const RootStatus(
        state: RootState.checking,
        manager: RootManager.unknown,
        managerDisplay: '探测中…',
      );

  factory RootStatus.fromJsonString(String jsonStr) {
    try {
      final Map<String, dynamic> j =
          (jsonDecode(jsonStr) as Map).cast<String, dynamic>();
      final String s = (j['state'] as String?) ?? 'error';
      final RootState rs = switch (s) {
        'available' => RootState.available,
        'none' => RootState.none,
        'denied' => RootState.denied,
        'timeout' => RootState.timeout,
        'error' => RootState.error,
        _ => RootState.error,
      };
      final dynamic uid = j['uid'];
      return RootStatus(
        state: rs,
        manager: RootManager.parse(j['manager'] as String?),
        managerDisplay: (j['managerDisplay'] as String?) ?? '未知',
        suggestion: j['suggestion'] as String?,
        suVersion: j['suVersion'] as String?,
        uid: uid is int ? uid : (uid is num ? uid.toInt() : null),
        timeoutMs: () {
          final n = j['timeoutMs'];
          if (n is int) return n;
          if (n is num) return n.toInt();
          return null;
        }(),
        rawError: j['rawError'] as String?,
      );
    } catch (e, stackTrace) {
      AppLogger.instance.e(
          'RootShell', 'RootStatus JSON parse failed: $e', stackTrace);
      return RootStatus(
        state: RootState.error,
        manager: RootManager.unknown,
        managerDisplay: '未知',
        rawError: 'JSON parse failed: $e',
      );
    }
  }
}

/// Root Shell v2 —— 适配 KernelSU 的自动夺权桥
///
/// 用法（Dart 端）：
///  1) 在 main() / App 启动时调用 `RootShell.instance.tryAcquireRoot()`
///     —— 非阻塞，5s 内给结果，结果写入 `statusNotifier`
///  2) UI 监听 `RootShell.instance.statusNotifier`
///     或者在 HomePage 里 `RootStatusBadge` 组件直接绑定
///  3) 失败长按 badge = 打开 KernelSU/Magisk/APatch 管理器
///  4) 失败点击 badge = 重新 tryAcquireRoot() 探测
class RootShell {
  RootShell._();
  static final RootShell instance = RootShell._();

  static const MethodChannel _channel =
      MethodChannel('com.cuktech.controller/root_shell');

  final ValueNotifier<RootStatus> statusNotifier =
      ValueNotifier<RootStatus>(RootStatus.unknown());

  RootStatus get status => statusNotifier.value;

  // ---------- 核心：非阻塞夺权（启动就跑） ----------

  /// 自动夺权：超时内反复探测直到 uid=0 / 明确失败
  ///
  /// [timeoutMs] 每次 `su -c id` 的最大等待，默认 5000ms。
  /// [retries] 如果 TIMEOUT 或冷启动首次 DENIED，再重试的次数。
  /// [silentIfAvailable] true = 已经 available 就直接返回不再重复探测。
  Future<RootStatus> tryAcquireRoot({
    int timeoutMs = 5000,
    int retries = 2,
    bool silentIfAvailable = true,
  }) async {
    if (silentIfAvailable && status.state == RootState.available) {
      return status;
    }
    statusNotifier.value = RootStatus.checking();

    RootStatus last = statusNotifier.value;
    for (int i = 0; i <= retries; i++) {
      try {
        final String? json = await _channel.invokeMethod<String>(
          'probeRoot',
          <String, dynamic>{'timeoutMs': timeoutMs},
        );
        if (json == null || json.isEmpty) {
          last = const RootStatus(
            state: RootState.error,
            manager: RootManager.unknown,
            managerDisplay: '未知',
            suggestion: '探测返回空结果',
          );
        } else {
          last = RootStatus.fromJsonString(json);
        }
        statusNotifier.value = last;
        _logStatus(last, attempt: i + 1, retries: retries);
        if (last.isOk) return last;           // ✅ 夺权成功，收工
        if (last.state == RootState.timeout && i < retries) {
          // 超时 = 第一次还没点过授权，用户可能正在点，退避后再试
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        if (last.state == RootState.denied && i < retries) {
          // KSU 守护进程冷启动偶发的首次 exit != 0，短暂退避重试
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        // none / error / (timeout|denied 最后一次) — 结束
        return last;
      } on PlatformException catch (e, stackTrace) {
        last = RootStatus(
          state: RootState.error,
          manager: RootManager.unknown,
          managerDisplay: '未知',
          suggestion: 'MethodChannel 调用失败: ${e.code} ${e.message}',
          rawError: '${e.details}',
        );
        statusNotifier.value = last;
        AppLogger.instance.e('RootShell', 'probeRoot Platform: ${e.message}', stackTrace);
        if (i < retries) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        return last;
      } catch (e, stackTrace) {
        last = RootStatus(
          state: RootState.error,
          manager: RootManager.unknown,
          managerDisplay: '未知',
          suggestion: '探测出现异常：$e',
        );
        statusNotifier.value = last;
        AppLogger.instance.e('RootShell', 'probeRoot exception: $e', stackTrace);
        return last;
      }
    }
    return last;
  }

  /// 打开对应 root 管理器 App（KSU/Magisk/APatch）
  ///
  /// auto = 按当前检测到的 manager 自动选择包名；否则传 'kernelsu'/'magisk'。
  Future<bool> openRootManager([String manager = 'auto']) async {
    try {
      final bool? r = await _channel.invokeMethod<bool>(
        'openRootManager',
        <String, dynamic>{'manager': manager},
      );
      return r ?? false;
    } catch (e, stackTrace) {
      AppLogger.instance.e('RootShell', 'openRootManager failed: $e', stackTrace);
      return false;
    }
  }

  // ---------- 命令执行 ----------

  /// 异步执行白名单内的 root 命令（推荐使用）
  Future<String> runCommandAsync(String command, {int timeoutMs = 8000}) async {
    try {
      final String? out = await _channel.invokeMethod<String>(
        'runCommandAsync',
        <String, dynamic>{'command': command, 'timeoutMs': timeoutMs},
      );
      return out ?? '';
    } on PlatformException catch (e, stackTrace) {
      AppLogger.instance.e(
        'RootShell',
        'runCommandAsync PlatformException: code=${e.code} msg=${e.message}',
        stackTrace,
      );
      rethrow;
    }
  }

  /// 异步读取米家数据库 (base64 encoded DB blob)
  Future<String> readMiotDbAsync({
    String dbPath = '/data/data/com.xiaomi.smarthome/databases/miio2.db',
  }) async {
    try {
      final String? out = await _channel.invokeMethod<String>(
        'readMiotDbAsync',
        <String, dynamic>{'dbPath': dbPath},
      );
      return out ?? '';
    } on PlatformException catch (e, stackTrace) {
      AppLogger.instance.e(
        'RootShell',
        'readMiotDbAsync PlatformException: ${e.code} ${e.message}',
        stackTrace,
      );
      rethrow;
    }
  }

  // ================================================================
  // — 以下为 v1 兼容 API（仍可用，但底层已走新异步实现） —
  // ================================================================

  /// 是否最近一次探测得到了 uid=0
  bool get isRootAvailable => status.state == RootState.available;

  /// 向后兼容：调用新的 probeRoot() 并只返回 true/false
  Future<bool> checkRoot() async {
    final RootStatus s = await tryAcquireRoot(silentIfAvailable: false);
    return s.isOk;
  }

  /// 向后兼容：等价于 runCommandAsync
  Future<String> runCommand(String command) => runCommandAsync(command);

  /// 向后兼容：等价于 readMiotDbAsync
  Future<String> readMiotDb({
    String dbPath = '/data/data/com.xiaomi.smarthome/databases/miio2.db',
  }) =>
      readMiotDbAsync(dbPath: dbPath);

  // ================================================================
  //                     日志工具
  // ================================================================
  void _logStatus(RootStatus s, {required int attempt, required int retries}) {
    final tag = switch (s.state) {
      RootState.available => '✅ AVAILABLE',
      RootState.timeout => '⏳ TIMEOUT',
      RootState.denied => '🚫 DENIED',
      RootState.none => '⚠️  NONE',
      RootState.error => '💥 ERROR',
      _ => '...',
    };
    final String ver =
        s.suVersion == null || s.suVersion!.isEmpty ? '(no su -V output)' : s.suVersion!;
    AppLogger.instance.i(
      'RootShell',
      '$tag (attempt $attempt/${retries + 1}) '
      'manager=${s.manager.displayName}[$ver] '
      'uid=${s.uid ?? '-'} '
      'suggestion=${s.suggestion?.split('\n').first}',
    );
    if (s.rawError != null) {
      AppLogger.instance.w('RootShell', 'rawError=${s.rawError}');
    }
  }
}
