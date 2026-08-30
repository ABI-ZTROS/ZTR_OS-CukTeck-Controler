import '../utils/logger/logger.dart';
import '../utils/root/root_shell.dart';
import 'models.dart';
import 'secure_token_store.dart';

/// TokenService —— 对外暴露的统一 Token 管理服务
///
/// 职责：
///   1. 从 miio2.db 扫描设备列表（本地路径）
///   2. 持久化用户选择的 Token 配置
///   3. 在本地失败时标记需要云端登录
class TokenService {
  TokenService._();
  static final TokenService instance = TokenService._();

  final SecureTokenStore _store = SecureTokenStore.instance;
  final RootShell _root = RootShell.instance;

  /// 从列表中选择一个设备并保存 Token 配置
  Future<TokenConfig> selectAndSave(MiioDevice device) async {
    final config = TokenConfig(
      token: device.token,
      key: '', // BLE Key 后续通过云 API 补充
      did: device.did,
      userId: '',
      deviceMac: device.mac,
      deviceName: device.name,
      deviceModel: device.model,
    );
    await _store.write(config);
    return config;
  }

  /// 读取已保存的 Token 配置
  Future<TokenConfig?> getSaved() => _store.read();

  /// 清除已保存 Token
  Future<void> clearSaved() => _store.clear();

  /// 是否已配置
  Future<bool> get hasConfigured => _store.hasToken();
}
