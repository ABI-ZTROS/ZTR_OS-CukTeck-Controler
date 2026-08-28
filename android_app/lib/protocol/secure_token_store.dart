import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/logger/logger.dart';
import 'models.dart';

/// 基于 flutter_secure_storage 的 Token 持久化层
///
/// 数据以 AES-256 加密存储在 Android Keystore / iOS Keychain。
/// 键名前缀使用 `cuk_` 避免冲突。
class SecureTokenStore {
  SecureTokenStore._();
  static final SecureTokenStore instance = SecureTokenStore._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static const String _kToken = 'cuk_token';
  static const String _kKey = 'cuk_key';
  static const String _kDid = 'cuk_did';
  static const String _kUserId = 'cuk_user_id';
  static const String _kDeviceMac = 'cuk_device_mac';
  static const String _kDeviceName = 'cuk_device_name';
  static const String _kDeviceModel = 'cuk_device_model';

  /// 读取当前保存的 Token 配置
  Future<TokenConfig?> read() async {
    try {
      final token = await _storage.read(key: _kToken);
      final key = await _storage.read(key: _kKey);
      final did = await _storage.read(key: _kDid);
      final userId = await _storage.read(key: _kUserId);
      final mac = await _storage.read(key: _kDeviceMac);
      final name = await _storage.read(key: _kDeviceName);
      final model = await _storage.read(key: _kDeviceModel);

      if (token == null || token.isEmpty) return null;

      return TokenConfig(
        token: token,
        key: key ?? '',
        did: did ?? '',
        userId: userId ?? '',
        deviceMac: mac ?? '',
        deviceName: name ?? '',
        deviceModel: model ?? '',
      );
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'read failed: $e', stackTrace);
      return null;
    }
  }

  /// 保存 Token 配置
  Future<void> write(TokenConfig config) async {
    try {
      await Future.wait(<Future<void>>[
        _storage.write(key: _kToken, value: config.token),
        _storage.write(key: _kKey, value: config.key),
        _storage.write(key: _kDid, value: config.did),
        _storage.write(key: _kUserId, value: config.userId),
        _storage.write(key: _kDeviceMac, value: config.deviceMac),
        _storage.write(key: _kDeviceName, value: config.deviceName),
        _storage.write(key: _kDeviceModel, value: config.deviceModel),
      ]);
      AppLogger.instance.i(
        'SecureTokenStore',
        'Saved token for DID=${config.did}',
      );
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'write failed: $e');
      rethrow;
    }
  }

  /// 清除所有存储的 Token 数据
  Future<void> clear() async {
    try {
      await _storage.deleteAll();
      AppLogger.instance.i('SecureTokenStore', 'Cleared all tokens');
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'clear failed: $e');
      rethrow;
    }
  }

  /// 是否已存在 Token
  Future<bool> hasToken() async {
    final cfg = await read();
    return cfg != null && cfg.isValid;
  }
}
