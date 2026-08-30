import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';

import '../utils/logger/logger.dart';
import 'models.dart';

/// 基于 flutter_secure_storage 的 Token 持久化层
///
/// 数据以 AES-256 加密存储在 Android Keystore / iOS Keychain。
/// 键名前缀使用 `cuk_` 避免冲突。
///
/// 同时支持跨平台 JSON 导出/导入：
///   - 手机登录后 → 导出 .cuk 文件 → 发到电脑 → Windows 端导入
///   - 格式见 [CloudCredentials.toExportJson]
class SecureTokenStore {
  SecureTokenStore._();
  static final SecureTokenStore instance = SecureTokenStore._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // === 米家云凭证 key ===
  static const String _kCloudUserId = 'cuk_cloud_user_id';
  static const String _kCloudSsecurity = 'cuk_cloud_ssecurity';
  static const String _kCloudServiceToken = 'cuk_cloud_service_token';
  static const String _kCloudDid = 'cuk_cloud_did';
  static const String _kCloudBeaconKey = 'cuk_cloud_beacon_key';
  static const String _kCloudDeviceName = 'cuk_cloud_device_name';
  static const String _kCloudDeviceModel = 'cuk_cloud_device_model';

  // === BLE / 本地 Token key（保留兼容）===
  static const String _kBleToken = 'cuk_token';
  static const String _kBleKey = 'cuk_key';
  static const String _kBleDid = 'cuk_did';
  static const String _kLegacyUserId = 'cuk_user_id';
  static const String _kDeviceMac = 'cuk_device_mac';
  static const String _kDeviceName = 'cuk_device_name';
  static const String _kDeviceModel = 'cuk_device_model';

  // ================================================================
  //  米家云凭证读写
  // ================================================================

  /// 读取米家云凭证
  Future<CloudCredentials?> readCloud() async {
    try {
      final userId = await _storage.read(key: _kCloudUserId);
      final ssecurity = await _storage.read(key: _kCloudSsecurity);
      final serviceToken = await _storage.read(key: _kCloudServiceToken);

      if (ssecurity == null || ssecurity.isEmpty) return null;

      return CloudCredentials(
        userId: userId ?? '',
        ssecurity: ssecurity,
        serviceToken: serviceToken ?? '',
        did: await _storage.read(key: _kCloudDid) ?? '',
        beaconKey: await _storage.read(key: _kCloudBeaconKey) ?? '',
        deviceName: await _storage.read(key: _kCloudDeviceName) ?? '',
        deviceModel: await _storage.read(key: _kCloudDeviceModel) ?? '',
      );
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'readCloud failed: $e', stackTrace);
      return null;
    }
  }

  /// 保存米家云凭证
  Future<void> writeCloud(CloudCredentials cred) async {
    try {
      await Future.wait(<Future<void>>[
        _storage.write(key: _kCloudUserId, value: cred.userId),
        _storage.write(key: _kCloudSsecurity, value: cred.ssecurity),
        _storage.write(key: _kCloudServiceToken, value: cred.serviceToken),
        _storage.write(key: _kCloudDid, value: cred.did),
        _storage.write(key: _kCloudBeaconKey, value: cred.beaconKey),
        _storage.write(key: _kCloudDeviceName, value: cred.deviceName),
        _storage.write(key: _kCloudDeviceModel, value: cred.deviceModel),
      ]);
      AppLogger.instance.i('SecureTokenStore',
          '✅ Cloud creds saved: user=${cred.userId}, did=${cred.did}, beacon=${cred.beaconKey.isNotEmpty}');
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'writeCloud failed: $e', stackTrace);
      rethrow;
    }
  }

  /// 清除米家云凭证
  Future<void> clearCloud() async {
    try {
      await Future.wait(<Future<void>>[
        _storage.delete(key: _kCloudUserId),
        _storage.delete(key: _kCloudSsecurity),
        _storage.delete(key: _kCloudServiceToken),
        _storage.delete(key: _kCloudDid),
        _storage.delete(key: _kCloudBeaconKey),
        _storage.delete(key: _kCloudDeviceName),
        _storage.delete(key: _kCloudDeviceModel),
      ]);
      AppLogger.instance.i('SecureTokenStore', 'Cleared cloud creds');
    } catch (e) {
      AppLogger.instance.e('SecureTokenStore', 'clearCloud failed: $e');
    }
  }

  Future<bool> hasCloud() async {
    final c = await readCloud();
    return c != null && c.isValid;
  }

  // ================================================================
  //  BLE / 本地 Token（兼容保留）
  // ================================================================

  Future<TokenConfig?> read() async {
    try {
      final token = await _storage.read(key: _kBleToken);
      final key = await _storage.read(key: _kBleKey);
      final did = await _storage.read(key: _kBleDid);

      if (token == null || token.isEmpty) return null;

      return TokenConfig(
        token: token,
        key: key ?? '',
        did: did ?? '',
        userId: await _storage.read(key: _kLegacyUserId) ?? '',
        deviceMac: await _storage.read(key: _kDeviceMac) ?? '',
        deviceName: await _storage.read(key: _kDeviceName) ?? '',
        deviceModel: await _storage.read(key: _kDeviceModel) ?? '',
      );
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'read failed: $e', stackTrace);
      return null;
    }
  }

  Future<void> write(TokenConfig config) async {
    try {
      await Future.wait(<Future<void>>[
        _storage.write(key: _kBleToken, value: config.token),
        _storage.write(key: _kBleKey, value: config.key),
        _storage.write(key: _kBleDid, value: config.did),
        _storage.write(key: _kLegacyUserId, value: config.userId),
        _storage.write(key: _kDeviceMac, value: config.deviceMac),
        _storage.write(key: _kDeviceName, value: config.deviceName),
        _storage.write(key: _kDeviceModel, value: config.deviceModel),
      ]);
      AppLogger.instance.i('SecureTokenStore', 'Saved token for DID=${config.did}');
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'write failed: $e');
      rethrow;
    }
  }

  Future<void> clear() async {
    try {
      await _storage.deleteAll();
      AppLogger.instance.i('SecureTokenStore', 'Cleared ALL storage');
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'clear failed: $e');
      rethrow;
    }
  }

  Future<bool> hasToken() async {
    final cfg = await read();
    return cfg != null && cfg.isValid;
  }

  // ================================================================
  //  🚀 跨平台 JSON 导出 / 导入
  // ================================================================

  /// 导出全部凭证为 JSON，通过系统分享发送（微信/QQ/邮件）
  Future<String?> exportAndShare() async {
    final json = await exportToJson();
    if (json == null) return null;

    try {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/cuk_cloud_$ts.cuk';
      final file = File(path);
      await file.writeAsString(json);

      // share_plus 7.x API: Share.shareFiles(List<String>)
      await Share.shareXFiles(
        [XFile(path)],
        text: '酷态科云凭证 — 可直接在 Windows 端导入使用',
        subject: 'CUKTECH Cloud Credentials',
      );

      AppLogger.instance.i('SecureTokenStore', '📤 Exported & shared');
      return path;
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'Export failed: $e', stackTrace);
      return null;
    }
  }

  /// 导出全部凭证为 JSON 字符串
  Future<String?> exportToJson() async {
    final cloud = await readCloud();
    if (cloud == null || !cloud.isValid) {
      AppLogger.instance.w('SecureTokenStore', 'No valid cloud creds to export');
      return null;
    }

    final map = <String, dynamic>{
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'xiaomi_cloud': cloud.toExportJson(),
    };

    AppLogger.instance.i('SecureTokenStore', '📤 Export JSON ready');
    return jsonEncode(map);
  }

  /// 从 JSON 字符串导入凭证
  /// 返回 true 表示导入成功
  Future<bool> importFromJson(String json) async {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final ver = map['version'] as int? ?? 0;

      if (ver != 1) {
        AppLogger.instance.e('SecureTokenStore',
            'Unsupported export version: $ver');
        return false;
      }

      final cloudJson = map['xiaomi_cloud'] as Map<String, dynamic>?;
      if (cloudJson == null) {
        AppLogger.instance.e('SecureTokenStore', 'Missing xiaomi_cloud field');
        return false;
      }

      final cred = CloudCredentials.fromExportJson(cloudJson);
      if (!cred.isValid) {
        AppLogger.instance.e('SecureTokenStore', 'Imported creds invalid');
        return false;
      }

      await writeCloud(cred);
      AppLogger.instance.i('SecureTokenStore',
          '📥 Import OK: user=${cred.userId}, did=${cred.did}');
      return true;
    } catch (e, stackTrace) {
      AppLogger.instance.e('SecureTokenStore', 'Import failed: $e', stackTrace);
      return false;
    }
  }
}

// ================================================================
//  米家云凭证数据类
// ================================================================

/// 米家云凭证 —— 跨平台可导出/导入
///
/// 关键字段：
///   - ssecurity:     RC4 API 签名密钥（32 字节 Base64）
///   - serviceToken:  服务端返回的会话令牌
///   - userId:        米家账号数字 ID
///   - did:           设备 ID（如 blt.3.1oc5esmigcc02）
///   - beaconKey:     BLE 认证密钥（32 位 hex）
class CloudCredentials {
  const CloudCredentials({
    required this.userId,
    required this.ssecurity,
    required this.serviceToken,
    this.did = '',
    this.beaconKey = '',
    this.deviceName = '',
    this.deviceModel = '',
  });

  final String userId;
  final String ssecurity;
  final String serviceToken;
  final String did;
  final String beaconKey;
  final String deviceName;
  final String deviceModel;

  bool get isValid =>
      ssecurity.isNotEmpty && serviceToken.isNotEmpty && userId.isNotEmpty;

  Map<String, dynamic> toExportJson() => <String, dynamic>{
        'userId': userId,
        'ssecurity': ssecurity,
        'serviceToken': serviceToken,
        'did': did,
        'beaconKey': beaconKey,
        'deviceName': deviceName,
        'deviceModel': deviceModel,
      };

  factory CloudCredentials.fromExportJson(Map<String, dynamic> json) {
    return CloudCredentials(
      userId: json['userId'] as String? ?? '',
      ssecurity: json['ssecurity'] as String? ?? '',
      serviceToken: json['serviceToken'] as String? ?? '',
      did: json['did'] as String? ?? '',
      beaconKey: json['beaconKey'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? '',
      deviceModel: json['deviceModel'] as String? ?? '',
    );
  }

  CloudCredentials copyWith({
    String? userId,
    String? ssecurity,
    String? serviceToken,
    String? did,
    String? beaconKey,
    String? deviceName,
    String? deviceModel,
  }) {
    return CloudCredentials(
      userId: userId ?? this.userId,
      ssecurity: ssecurity ?? this.ssecurity,
      serviceToken: serviceToken ?? this.serviceToken,
      did: did ?? this.did,
      beaconKey: beaconKey ?? this.beaconKey,
      deviceName: deviceName ?? this.deviceName,
      deviceModel: deviceModel ?? this.deviceModel,
    );
  }
}
