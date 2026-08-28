import '../utils/root/root_shell.dart';
import '../utils/logger/logger.dart';
import 'models.dart';

/// Token 仓库 —— 安全存储与读取米家认证 Token，并解析 miio2.db 设备列表
///
/// 上半部分：用户级 Token 安全存储（flutter_secure_storage，待接入）。
/// 下半部分：通过 [RootShell] 执行 sqlite3 命令，从 miio2.db 提取
/// 米家设备列表（含酷态科充电器识别）。
class TokenRepository {
  TokenRepository._();
  static final TokenRepository instance = TokenRepository._();

  // ===========================================================================
  // 安全存储（用户级 Token）
  // ===========================================================================

  // TODO: 接入 flutter_secure_storage
  TokenConfig? _cachedToken;

  /// 获取当前存储的 Token
  Future<TokenConfig?> getToken() async {
    // TODO: 从 flutter_secure_storage 读取
    AppLogger.instance.d('TokenRepository', 'Loading token from secure storage');
    return _cachedToken;
  }

  /// 保存 Token
  Future<void> saveToken(TokenConfig token) async {
    // TODO: 写入 flutter_secure_storage
    _cachedToken = token;
    AppLogger.instance.i('TokenRepository', 'Token saved for user: ${token.userId}');
  }

  /// 清除 Token
  Future<void> clearToken() async {
    // TODO: 从 flutter_secure_storage 删除
    _cachedToken = null;
    AppLogger.instance.i('TokenRepository', 'Token cleared');
  }

  /// 检查 Token 是否存在
  Future<bool> hasToken() async {
    final TokenConfig? token = await getToken();
    return token?.isValid ?? false;
  }

  // ===========================================================================
  // miio2.db 解析
  // ===========================================================================

  static const String _dbPath =
      '/data/data/com.xiaomi.smarthome/databases/miio2.db';

  /// SQL 语句：读取 devices 表的核心字段
  static const String _sql =
      'select did, model, token, mac, name from devices;';

  /// 从 miio2.db 读取所有米家设备
  ///
  /// [forceRoot] 是否强制通过 Root 读取（默认 true）
  /// 返回 [MiioDbResult]，包含成功/失败状态与设备列表。
  Future<MiioDbResult> loadDevices({bool forceRoot = true}) async {
    try {
      AppLogger.instance.i('TokenRepository', 'Loading devices from $_dbPath');

      // 1. 通过 RootShell 执行 sqlite3 命令
      final raw = await RootShell.instance
          .runCommand('sqlite3 $_dbPath "$_sql"');

      if (raw.isEmpty) {
        // 空结果：可能无设备，也可能 sqlite3 执行失败
        AppLogger.instance.w('TokenRepository', 'Empty sqlite3 output');
        return MiioDbResult.failure(MiioDbErrors.emptyResult);
      }

      if (raw.startsWith('ERR:')) {
        // 有错误前缀
        final errText = raw.substring(4).trim();
        AppLogger.instance.e('TokenRepository', 'sqlite3 error: $errText');
        if (errText.contains('no such file') || errText.contains('cannot open')) {
          return MiioDbResult.failure(MiioDbErrors.dbNotFound);
        }
        if (errText.contains('permission denied')) {
          return MiioDbResult.failure(MiioDbErrors.noPermission);
        }
        return MiioDbResult.failure(MiioDbErrors.parseError);
      }

      // 2. 解析每行（sqlite3 默认 `|` 分隔）
      final devices = <MiioDevice>[];
      final lines = raw.split('\n');
      for (final line in lines) {
        try {
          final device = _parseLine(line);
          if (device != null) devices.add(device);
        } catch (e, stackTrace) {
          // 单行解析失败不中断整体
          AppLogger.instance.e(
            'TokenRepository',
            'Parse line failed: $e line=$line',
            stackTrace,
          );
        }
      }

      AppLogger.instance
          .i('TokenRepository', 'Loaded ${devices.length} devices');
      return MiioDbResult.success(devices);
    } on Exception catch (e, stackTrace) {
      AppLogger.instance.e('TokenRepository', 'loadDevices failed: $e', stackTrace);
      return MiioDbResult.failure(MiioDbErrors.parseError);
    }
  }

  /// 解析单行 sqlite3 输出（`did|model|token|mac|name`）
  MiioDevice? _parseLine(String line) {
    if (line.trim().isEmpty) return null;
    final parts = line.split('|');
    if (parts.length < 5) {
      AppLogger.instance
          .w('TokenRepository', 'Bad line (${parts.length} cols): $line');
      return null;
    }
    return MiioDevice(
      did: parts[0].trim(),
      model: parts[1].trim(),
      token: parts[2].trim(),
      mac: parts[3].trim(),
      name: parts[4].trim(),
    );
  }

  /// 从设备列表中按 did 查找
  MiioDevice? findByDid(List<MiioDevice> devices, String did) {
    for (final d in devices) {
      if (d.did == did) return d;
    }
    return null;
  }

  /// 从设备列表中按 model 前缀过滤酷态科设备
  List<MiioDevice> findCuktechDevices(List<MiioDevice> devices) {
    return devices.where((d) => d.isCuktech).toList(growable: false);
  }
}